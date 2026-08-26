# kind verification — scenario 5: version change = bnk down then bnk up (commit 9c2e929)

Installed at 2.4.0-0.0.1 (scenario 5a). The stub `bnk up` fails loudly if a different version is applied over an installed one — i.e. if the chart ever attempted an in-place upgrade.

== 5a. re-sync at 2.4.0-0.0.1 (no version change → no-op)
Succeeded|Synced|Healthy
outcome=succeeded deployed=true post-sync bnk status captured
== 5b. bump ROKSBNKCTL_MANIFEST_VERSION → 2.4.1-0.0.1, sync (expect bnk down, then bnk up)
