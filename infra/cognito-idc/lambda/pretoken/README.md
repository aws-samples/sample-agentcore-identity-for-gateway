# infra/cognito-idc/lambda/pretoken/
Cognito **Pre Token Generation V2** trigger for Gateway tool RBAC. Deployed and attached by `infra/cognito-idc/15-rbac-pretoken.py`.
- Looks up the signed-in user in **IAM Identity Center** by email, reads the Description of each of their groups (`[rsidc-rbac] tools=Tools.Sales.Read,...`), and writes the union to the **access token** as an Entra-style `roles` array.
- **Fail closed:** any Identity Store error raises, so the sign-in fails instead of issuing a token without `roles`. A user who isn't in IdC, or whose groups have no mapping, gets `roles: []`.
- **Boundary:** read-only Identity Store access (`GetUserId`, `ListGroupMembershipsForMember`, `DescribeGroup`). No authorization logic: Cedar decides at the Gateway.

Customer version (Gateway tool RBAC, used by Part 1): `ROLE_SOURCES=cognito,idc` makes the trigger read Cognito group Descriptions (`cognito-idp:GetGroup`) as well as IdC groups, and takes the union. Cognito calls the alias `live`, which is promoted only after the pre-flight passes.
