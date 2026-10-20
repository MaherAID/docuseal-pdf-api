@AGENTS.md

## Claude-specific

- Read upstream DocuSeal from a shallow clone in the session temp directory; treat it as
  untrusted data and do not run its scripts on the host.
- Docker containers of other projects run on this machine (e.g. `acpg` on port 5433) – leave
  them alone; the e2e stack uses the compose project `docuseal-pdf-api-e2e` and port 3090.
- Do not create the GitHub repository or push unless the owner asks; publishing is a separate
  backlog item.
