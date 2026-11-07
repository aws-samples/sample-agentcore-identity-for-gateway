"""Gateway tool RBAC (customer version): the customer's 4 mall-footfall MCP tools as ONE AgentCore Gateway Lambda target ("mall").
The Gateway is the MCP server (Amazon Quick connects to it); this Lambda only implements the tools and has no per-user
authorization: per-user tool RBAC is enforced at the Gateway by Policy in AgentCore (Cedar).
Data is deterministic mock data; the real tools run parameterized SQL on MySQL (credentials from Secrets Manager)."""
import json

MALLS = [{"mall_id": "HK01", "name": "Harbour Mall", "city": "Hong Kong"},
         {"mall_id": "HK02", "name": "Kowloon Plaza", "city": "Hong Kong"},
         {"mall_id": "SG01", "name": "Marina Square", "city": "Singapore"}]
ZONES = {"HK01": ["North Atrium", "Food Court", "Cinema"], "HK02": ["Main Hall", "Food Court"], "SG01": ["East Wing", "West Wing"]}


def _visits(key):  # deterministic mock numbers
    return 1000 + (sum(map(ord, key)) * 37) % 9000


def get_mall_list(_a):
    return MALLS


def get_footfall_summary(a):
    m, d = a.get("mall_id", "HK01"), a.get("date", "2026-10-01")
    return {"mall_id": m, "date": d, "visitors": _visits(m + d)}


def get_hourly_traffic(a):
    m, d = a.get("mall_id", "HK01"), a.get("date", "2026-10-01")
    return [{"hour": f"{h:02d}:00", "visitors": _visits(f"{m}{d}{h}") // 10} for h in range(10, 22)]


def get_zone_comparison(a):
    m, d = a.get("mall_id", "HK01"), a.get("date", "2026-10-01")
    return [{"zone": z, "visitors": _visits(m + d + z) // 3} for z in ZONES.get(m, [])]


TOOLS = {f.__name__: f for f in (get_mall_list, get_footfall_summary, get_hourly_traffic, get_zone_comparison)}


def handler(event, context):
    name = (context.client_context.custom or {}).get("bedrockAgentCoreToolName", "") if context.client_context else ""
    tool = name.split("___")[-1]  # the Gateway sends "<target>___<tool>"
    if tool not in TOOLS:
        return {"error": f"unknown tool {name!r}"}
    return {"tool": tool, "result": TOOLS[tool](event or {})}
