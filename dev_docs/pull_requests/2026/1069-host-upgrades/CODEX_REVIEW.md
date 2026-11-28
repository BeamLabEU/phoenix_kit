# PR #1069 review

| Severity | Finding and fix |
| --- | --- |
| BUG - HIGH | First-Owner setup accepted a missing client address as evidence of a local development request. Require a known loopback client and loopback host. Hosts without peer information can use the setup link or console. |
| BUG - HIGH | Under open sign-up, the first-Owner grant ignored the explicit denial used by admin-created accounts. The grant now honors an explicit denial under every policy. |
| BUG - HIGH | Console Owner creation committed the grant before invalidating the setup token. A failed deletion could leave a token valid if the Owner later became inactive. The grant and deletion now commit together. A PostgreSQL regression checks rollback and a successful retry. |
| BUG - HIGH | The shared key changeset accepted a rate-limit override on a personal key, and personal-key management permission allowed later edits. Only the administrative creation path casts the override. Updates require API administration permission as well as authority over the key. |
| BUG - MEDIUM | File metadata responses include signed links and depend on the signed-in reader. Successful responses now use the same private, no-store headers as the rest of the guarded flow. |
| BUG - MEDIUM | The updater accepted malformed entries inside a patch map, allowing an intended refusal to be silently lost. Validate each ID and outcome on load, preserving valid entries from other versions. |
| BUG - MEDIUM | Text watermarks failed on installations where ImageMagick's default font was unavailable. Watermark labels now use the same configured or installed font selection as annotation thumbnails. |
