# Upstream Reference

This repository is intentionally fresh and has no Transmission history.

The local upstream/reference checkout remains:

```sh
/Users/wsb/trans
```

Use that checkout to fetch or inspect Transmission upstream:

```sh
git -C /Users/wsb/trans fetch --all --tags
git -C /Users/wsb/trans log --oneline --decorate -20
```

Backend material was lifted behavior-preserving from the Glass package inside `/Users/wsb/trans/glass` during the fresh rebuild. The new repository starts from a clean first commit named `glass`.

`mveinot/transmission-control` was reviewed as a modern Transmission RPC reference. Useful backend ideas carried into this direction are explicit queue RPC support, centralized session-token reuse, update coalescing, and cleanup only after successful `torrent-add`.
