"""AgentCore Runtime entrypoint: a data agent that queries/updates Redshift as the calling IdC user.

Payload:
  {"prompt": "..."}                 -> LLM agent decides which SQL to run (natural-language path)
  {"sql": "..."}                    -> run exactly this SQL as the caller (deterministic test path)
"""
import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent, tool
from strands.models import BedrockModel

from redshift_tools import run_sql as execute_as_user

app = BedrockAgentCoreApp()
MODEL_ID = os.environ.get("MODEL_ID", "global.anthropic.claude-sonnet-5-5")

SYSTEM_PROMPT = """You are a data agent for an Amazon Redshift warehouse (database 'dev').
Schemas: sales, marketing, risk. Always call the run_sql tool; never invent data.
You act with the end user's own Redshift permissions. If a statement is denied, report the exact
error and do NOT try to work around it (no alternative tables, no privilege changes).
Start by checking which tables you can see with:
  SELECT table_schema, table_name FROM svv_tables WHERE table_schema IN ('sales','marketing','risk')"""


def bearer_token(context) -> str:
    headers = {k.lower(): v for k, v in (context.request_headers or {}).items()}
    auth = headers.get("authorization", "")
    return auth.split(" ", 1)[1] if auth.lower().startswith("bearer ") else ""


@app.entrypoint
def invoke(payload, context):
    user_jwt = bearer_token(context)

    if payload.get("sql"):
        return {"mode": "sql", "result": execute_as_user(user_jwt, payload["sql"])}

    # Tool is a closure over THIS request's token, so identity can never leak across invocations.
    @tool
    def run_sql(sql: str) -> dict:
        """Run a single SQL statement on Redshift with the end user's permissions."""
        return execute_as_user(user_jwt, sql)

    agent = Agent(model=BedrockModel(model_id=MODEL_ID), system_prompt=SYSTEM_PROMPT, tools=[run_sql])
    result = agent(payload.get("prompt", "Who am I in Redshift? Run SELECT current_user."))
    return {"mode": "agent", "answer": str(result)}


if __name__ == "__main__":
    app.run()
