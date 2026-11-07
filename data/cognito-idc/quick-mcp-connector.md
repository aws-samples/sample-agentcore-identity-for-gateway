# Connect Amazon Quick to the mall Gateway (Part 1)

Goal: in **your** Amazon Quick account, connect the AgentCore Gateway `rsidc-mall-gateway` as an MCP server with
**user-level OAuth**. Then check two things: wei can use all 4 tools, and ds1 can use only 2. Nothing was created in
Quick by automation. This guide is for you to run by hand.

> **Why user-level OAuth is required:** with *service* authentication (client credentials), every Quick user shares
> one token with no `roles`, so per-user RBAC is impossible. You must select **user authentication (Custom user based OAuth)**.

## 1. Values to enter

| Quick field | Value |
|---|---|
| MCP server endpoint | `https://<your-gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp`. Use your own Gateway URL: it is shown on the Gateway page in the AgentCore console and printed by `infra/cognito-idc/16-mall-gateway.sh`. |
| Authentication | **User authentication**, i.e. *Custom user based OAuth*. **Not** service authentication. Leave *Public OAuth client* unchecked. |
| Client ID | `<quick-client-id>`: the ID of your Cognito app client `rsidc-quick-mcp`, printed by `infra/cognito-idc/16-mall-cognito.py` |
| Client secret | Run `cat tests/.quick-client.env` locally and copy `QUICK_CLIENT_SECRET`. This local, gitignored file is created by `infra/cognito-idc/16-mall-cognito.py`; never paste the secret anywhere else. |
| Authorization URL | `https://rsidc-123456789012.auth.ap-southeast-1.amazoncognito.com/oauth2/authorize` |
| Token URL | `https://rsidc-123456789012.auth.ap-southeast-1.amazoncognito.com/oauth2/token` |
| Scopes (if asked) | `openid email profile` |
| Redirect URL | Auto-filled by Quick as `https://<quick-region>.quicksight.aws.amazon.com/sn/oauthcallback`. It must be in the client's callback list (see below). |

**Callback list.** The client allows the Quick callbacks for us-east-1, us-west-2, ap-southeast-2 and eu-west-1. If the
Redirect URL that Quick shows is different, add it and re-run:
`QUICK_REDIRECTS="https://<region>.quicksight.aws.amazon.com/sn/oauthcallback" infra/common/run.sh .venv/bin/python infra/cognito-idc/16-mall-cognito.py`

**Login method.** Cognito doesn't support Dynamic Client Registration, so Quick falls back to the manual fields above.
Test passwords are in the local, gitignored `tests/.users.env` (`PW_wei`, `PW_ds1`, `PW_chen`), created by `infra/cognito-idc/02-cognito.sh`.

**Troubleshooting: "No access token was found for an OAuth authorization code connection".** Quick sends the RFC 8707
`resource=<gateway MCP URL>` parameter. Cognito accepts it only if a resource server with exactly that URL identifier exists
(created by `infra/cognito-idc/16-mall-cognito.py`). If you see this error, cancel the connector, then create it again.

## 2. Create the integration (sign in as wei)

1. In Quick, open **Integrations → Actions → Model Context Protocol → +**.
2. **Connect:** paste the endpoint and name the integration, e.g. `rsidc-mall`.
3. **Authenticate:** enter the values from section 1.
4. **Authorize:** the Cognito managed login opens. Sign in as **wei**.
5. **Review:** Quick lists the tools it discovered.
   - **Record what you see.** Expected: 4 tools, because wei's token has all 4 roles. The names may show as `mall___get_mall_list` and so on.
6. **Publish:** if your Quick account is shared, restrict the access scope to **yourself only**. Don't publish to the whole organization.

## 3. Test as wei

In a Quick chat or agent that has the integration enabled, ask each of the following. Expected: all succeed.

| Prompt | Tool |
|---|---|
| "List the malls" | `get_mall_list` |
| "Footfall for HK01 on 2026-10-01" | `get_footfall_summary` |
| "Hourly traffic for HK01 on 2026-10-01" | `get_hourly_traffic` |
| "Compare zones in HK01 on 2026-10-01" | `get_zone_comparison` |

## 4. Switch the connection to ds1

1. In Quick's integration or connection page, **sign out** or **disconnect** your OAuth connection.
2. Clear the Cognito session so you aren't silently signed back in as wei. Either use a private browser window for Quick, or delete cookies for `rsidc-123456789012.auth.ap-southeast-1.amazoncognito.com`.
3. **Reconnect** and sign in as **ds1**.

## 5. Test as ds1 (the key observations)

| Check | Expected (enforced by the Gateway) | What to record |
|---|---|---|
| A. Tool list shown in Quick | The Gateway returns **only 2 tools** to ds1 (`get_mall_list`, `get_footfall_summary`). | Does Quick's UI show 2 tools, or still 4? If 4, Quick **cached the tool list at creation** (with wei's token). |
| B. "List the malls" / "Footfall for HK01" | Succeeds | — |
| C. "Hourly traffic for HK01" | **Must fail.** The Gateway returns `Tool Execution Denied: Tool call not allowed due to policy enforcement` (HTTP 200, `isError=true`). | What Quick shows: an error, or the model saying it can't access the tool. It must **not** show hourly numbers. |
| D. "Compare zones in HK01" | Must fail, same as C | Same as C |

If Quick cached 4 tools (check A), the model may still *try* hourly or zone. That's fine for security, because every call is
decided by Cedar at the Gateway. It only affects user experience (the model may attempt tools that will be denied). Optionally,
test chen the same way: zero tools, and every call is denied.

## 6. Confirm on the AWS side

The Gateway logs every Policy decision:
```bash
aws logs filter-log-events --region ap-southeast-1 \
  --log-group-name /aws/vendedlogs/bedrock-agentcore/gateway/rsidc-mall-gateway \
  --start-time $(( ($(date +%s)-1800)*1000 )) --filter-pattern DENY \
  --query 'events[].message' --output text | grep -o '"decision":"DENY","reason":"[^"]*"' | sort | uniq -c
```
- **Calls ds1 shouldn't make:** expect `decision":"DENY"` entries for ds1's hourly and zone calls.
- **Every permitted call:** expect a `Tool invocation` with no DENY.

## 7. Notes for the customer

- **When permission changes apply:** change only the Cognito group Description (e.g. `mall-viewer`). The next token picks it up, either at a new sign-in or at the refresh token that Quick uses automatically. Tokens already issued keep their old `roles` until they expire, at most 60 minutes (the client's access token validity).
- **No changes needed elsewhere:** the MCP tools (Lambda), the Gateway and Cedar never change when people or groups change.
- **Cleanup:** to remove the Quick integration, delete it in Quick. The AWS side is torn down per the Customer version teardown in [part1-quick.html](part1-quick.html) (or `infra/cognito-idc/99-teardown.sh`).
