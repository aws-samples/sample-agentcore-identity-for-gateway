# webchat/tests/
Offline security checks for the GUI apps (no AWS, no network; boto3 clients are stubbed).
- `test_security.py`: inline-JSON escaping (F-02), 3LO callback session binding and single use (F-03), `Secure` cookie flag, session and pending-state TTL and size cap (F-04).
- Run from the repo root: `.venv/bin/python webchat/tests/test_security.py`.
- Not copied into the Lambda zip (`infra/cognito-idc/14-deploy-webchat.sh` copies named files only). Keep it free of real tokens and IDs.
