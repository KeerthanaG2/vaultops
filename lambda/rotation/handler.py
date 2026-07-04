# handler.py
# Lambda function implementing the 4-step Secrets Manager rotation protocol
# for the VaultOps RDS PostgreSQL password.
#
# Secrets Manager calls this Lambda automatically on the rotation schedule.
# It passes an event with two key fields:
#   - SecretId: ARN of the secret being rotated
#   - Step: which of the 4 steps to execute (one Lambda call per step)
#
# The secret stores JSON in this format:
# {"host": "...", "port": 5432, "dbname": "vaultops",
#  "username": "vaultops_user", "password": "..."}

import boto3
import json
import logging
import secrets
import string
import psycopg2


def build_alter_user_sql(username, password):
    """Build a safe PostgreSQL ALTER USER statement for the new password."""
    escaped_username = username.replace('"', '""')
    escaped_password = password.replace("'", "''")
    return f'ALTER USER "{escaped_username}" WITH PASSWORD \'{escaped_password}\''

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Secrets Manager client — uses Lambda's IAM execution role automatically.
# No hardcoded credentials needed.
sm_client = boto3.client("secretsmanager", region_name="ap-south-1")


def lambda_handler(event, context):
    """
    Main entry point. Routes to the correct step based on event["Step"].
    Secrets Manager calls this 4 times per rotation — once per step.
    """
    secret_id = event["SecretId"]
    step = event["Step"]

    logger.info(f"Rotation step: {step} for secret: {secret_id}")

    if step == "createSecret":
        create_secret(secret_id)
    elif step == "setSecret":
        set_secret(secret_id)
    elif step == "testSecret":
        test_secret(secret_id)
    elif step == "finishSecret":
        finish_secret(secret_id)
    else:
        raise ValueError(f"Unknown rotation step: {step}")


def generate_password(length=16):
    """
    Generate a cryptographically secure random password.
    Uses secrets module (not random) — secrets is designed for passwords,
    random is designed for simulations. Critical difference for security.
    """
    chars = string.ascii_letters + string.digits + "!#$%&*()-_=+[]{}?"
    return "".join(secrets.choice(chars) for _ in range(length))


def get_secret_value(secret_id, stage):
    """
    Helper to fetch a specific version of the secret.
    stage = "AWSCURRENT"  → the currently active password
    stage = "AWSPENDING"  → the new password staged for rotation
    """
    return json.loads(
        sm_client.get_secret_value(
            SecretId=secret_id,
            VersionStage=stage
        )["SecretString"]
    )


def create_secret(secret_id):
    """
    Step 1: Generate a new password and store it as AWSPENDING.
    We don't touch the database yet — just stage the new value in Secrets Manager.
    If AWSPENDING already exists (e.g. Lambda retried), skip generation to avoid
    creating a second pending version.
    """
    # Check if AWSPENDING already exists — idempotency check
    try:
        sm_client.get_secret_value(
            SecretId=secret_id,
            VersionStage="AWSPENDING"
        )
        logger.info("AWSPENDING already exists — skipping createSecret")
        return
    except sm_client.exceptions.ResourceNotFoundException:
        pass  # expected — no pending version yet, continue

    # Get current secret to copy connection details (host, port, dbname, username)
    current = get_secret_value(secret_id, "AWSCURRENT")

    # Generate new password — keep all other fields the same
    new_secret = {
        "host":     current["host"],
        "port":     current["port"],
        "dbname":   current["dbname"],
        "username": current["username"],
        "password": generate_password()
    }

    # Store as AWSPENDING — not active yet, just staged
    sm_client.put_secret_value(
        SecretId=secret_id,
        SecretString=json.dumps(new_secret),
        VersionStages=["AWSPENDING"]
    )
    logger.info("New password staged as AWSPENDING")


def set_secret(secret_id):
    """
    Step 2: Apply the AWSPENDING password to the actual RDS database.
    We connect using the CURRENT password, then ALTER USER to the PENDING password.
    After this, both passwords could work briefly — testSecret will verify PENDING.
    """
    current = get_secret_value(secret_id, "AWSCURRENT")
    pending = get_secret_value(secret_id, "AWSPENDING")

    # Connect using the still-valid CURRENT password
    conn = psycopg2.connect(
        host=current["host"].split(":")[0],  # strip port if included in host
        port=current["port"],
        dbname=current["dbname"],
        user=current["username"],
        password=current["password"],
        connect_timeout=10
    )
    conn.autocommit = True  # DDL commands like ALTER USER need autocommit

    try:
        with conn.cursor() as cur:
            # Update the DB user's password to the new PENDING value.
            # Use a quoted SQL string instead of parameter binding here because
            # PostgreSQL treats the identifier and password differently.
            cur.execute(build_alter_user_sql(current["username"], pending["password"]))
        logger.info("RDS user password updated to AWSPENDING value")
    finally:
        conn.close()


def test_secret(secret_id):
    """
    Step 3: Verify the AWSPENDING password actually works against RDS.
    This is the safety check — if the DB password update in setSecret failed
    for any reason, this step will raise an exception and abort the rotation.
    The old AWSCURRENT password stays active.
    """
    pending = get_secret_value(secret_id, "AWSPENDING")

    try:
        conn = psycopg2.connect(
            host=pending["host"].split(":")[0],
            port=pending["port"],
            dbname=pending["dbname"],
            user=pending["username"],
            password=pending["password"],  # using the NEW password
            connect_timeout=10
        )
        conn.close()
        logger.info("AWSPENDING password verified — RDS connection successful")
    except psycopg2.OperationalError as e:
        # This causes Secrets Manager to abort rotation — old password stays active
        logger.error(f"testSecret FAILED — new password doesn't work: {e}")
        raise


def finish_secret(secret_id):
    """
    Step 4: Promote AWSPENDING to AWSCURRENT.
    After this, the old password is AWSPREVIOUS (kept briefly for safety)
    and the new password is the active AWSCURRENT.
    Applications reading AWSCURRENT will now get the new password.
    """
    # Get the version IDs to update stages correctly
    metadata = sm_client.describe_secret(SecretId=secret_id)
    current_version = None

    for version_id, stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in stages:
            current_version = version_id
        if "AWSPENDING" in stages:
            pending_version = version_id

    if current_version == pending_version:
        logger.info("AWSPENDING is already AWSCURRENT — rotation already complete")
        return

    # Move AWSPENDING → AWSCURRENT, demote old AWSCURRENT → AWSPREVIOUS
    sm_client.update_secret_version_stage(
        SecretId=secret_id,
        VersionStage="AWSCURRENT",
        MoveToVersionId=pending_version,
        RemoveFromVersionId=current_version
    )
    logger.info("Rotation complete — AWSPENDING promoted to AWSCURRENT")
