# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |
| Previous| :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** create a public GitHub issue for the vulnerability
2. Email the details to: security@theyonecodes.com
2. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if known)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 5 business days
- **Fix Timeline**: Critical issues within 30 days, High within 60 days, Medium within 90 days

## Security Best Practices

This project follows these security practices:
- Dependencies are regularly scanned for vulnerabilities (`cargo audit`, `npm audit`, `pip-audit`, `bandit`)
- All releases are signed (Authenticode for Windows, GPG for Linux/macOS)
- CI/CD pipelines include security scanning (SAST, DAST, dependency scanning)
- Secrets are managed via GitHub Secrets, never committed to source
- Branch protection rules enforce PR reviews and status checks

## Responsible Disclosure

We follow coordinated vulnerability disclosure. We will:
- Acknowledge receipt within 48 hours
- Provide regular updates on fix progress
- Credit the reporter (unless they prefer anonymity)
- Publish a security advisory after the fix is released

## IFEO Shim Specific Security

The ElectronShim C# binary:
- Is signed with Authenticode (SHA-256)
- Has ACLs hardened to SYSTEM/Administrators only
- Uses `DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS` to prevent IFEO re-entry loops
- Logs all invocations for audit trail