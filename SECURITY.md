# Security Policy

## Reporting Security Vulnerabilities

**Do not open public issues for security vulnerabilities.**

We take security seriously. If you discover a security vulnerability, please report it responsibly.

## How to Report

### Email (Preferred)

Send an email to: **<4211002+mvillmow@users.noreply.github.com>**

Or use the GitHub private vulnerability reporting feature if available.

### What to Include

Please include as much of the following information as possible:

- **Description** - Clear description of the vulnerability
- **Impact** - Potential impact and severity assessment
- **Steps to reproduce** - Detailed steps to reproduce the issue
- **Affected files** - Which configuration files, workflows, or recipes are affected
- **Suggested fix** - If you have a suggested fix or mitigation

### Example Report

```text
Subject: [SECURITY] NATS config exposes unauthenticated monitoring port

Description:
The NATS server configuration in configs/nats/server.conf binds the
monitoring port to 0.0.0.0 without requiring authentication, allowing
any network-adjacent host to scrape cluster metadata.

Impact:
An attacker on the same network could enumerate connected clients,
subjects, and message rates to map internal service topology.

Steps to Reproduce:
1. Deploy NATS using configs/nats/server.conf
2. curl http://<host>:8222/connz
3. Observe unauthenticated connection metadata

Affected Files:
configs/nats/server.conf (monitoring block)

Suggested Fix:
Bind monitoring to 127.0.0.1 or require authentication token.
```

## Response Timeline

We aim to respond to security reports within the following timeframes:

| Stage                    | Timeframe              |
|--------------------------|------------------------|
| Initial acknowledgment   | 48 hours               |
| Preliminary assessment   | 1 week                 |
| Fix development          | Varies by severity     |
| Public disclosure        | After fix is released  |

## Severity Assessment

We use the following severity levels:

| Severity     | Description                          | Response           |
|--------------|--------------------------------------|--------------------|
| **Critical** | Remote code execution, data breach   | Immediate priority |
| **High**     | Privilege escalation, data exposure  | High priority      |
| **Medium**   | Limited impact vulnerabilities       | Standard priority  |
| **Low**      | Minor issues, hardening              | Scheduled fix      |

## Responsible Disclosure

We follow responsible disclosure practices:

1. **Report privately** - Do not disclose publicly until a fix is available
2. **Allow reasonable time** - Give us time to investigate and develop a fix
3. **Coordinate disclosure** - We will work with you on disclosure timing
4. **Credit** - We will credit you in the security advisory (if desired)

## What We Will Do

When you report a vulnerability:

1. Acknowledge receipt within 48 hours
2. Investigate and validate the report
3. Develop and test a fix
4. Release the fix and update affected configurations
5. Publish a security advisory

## Scope

### In Scope

- NATS configuration files (`configs/nats/*.conf`)
- Nomad configuration files (`configs/nomad/*.hcl`)
- Docker Compose files (`docker-compose*.yml`, `e2e/docker-compose*.yml`)
- CI/CD workflows (`.github/workflows/*.yml`)
- Justfile recipes (`justfile`)
- Submodule pinning (`.gitmodules`, submodule SHAs)

### Out of Scope

- Application code in submodule repositories (report vulnerabilities to that repo directly)
- Third-party integrations not maintained by us
- Social engineering attacks
- Physical security

## Security Best Practices

When contributing to HomericIntelligence infrastructure:

- Never commit secrets, API keys, tokens, or credentials to the repository
- Validate configuration files before committing (check for open ports, missing auth)
- Keep submodule pins current to avoid known vulnerabilities in pinned versions
- Use branch protection on `main` and require PR reviews for all changes
- Audit Nomad and NATS configs for least-privilege access

## Contact

For security-related questions that are not vulnerability reports:

- Open a GitHub Discussion with the "security" tag
- Email: <4211002+mvillmow@users.noreply.github.com>

---

Thank you for helping keep HomericIntelligence secure!
