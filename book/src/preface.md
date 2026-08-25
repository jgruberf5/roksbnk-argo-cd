# Preface

This book is a step-by-step guide to installing **F5 BIG-IP Next for Kubernetes
(BNK)** onto **Red Hat OpenShift on IBM Cloud (ROKS)** using **only Argo CD** —
no Argo Workflows, no laptop-driven CLI session, no pipeline runner other than
the one Argo CD itself schedules.

It assumes you already have a working Argo CD and know your way around its web
UI. Everything else — the IBM Cloud pieces, the F5 supply chain, the sizing
choices, and the roksbnkctl tool that does the heavy lifting inside Argo CD's
hook Jobs — is explained as you go.

Every screenshot in this book was captured from a real Argo CD instance
(upstream v3.5.1 on a small IBM Cloud VSI) driving a real BNK 2.4 install onto a
real ROKS 4.21 cluster, with a headless browser script that lives beside the
book so the pictures can be refreshed when the UI changes
([Appendix B](appendix-b-screenshots.md)). The logs shown are the logs those
runs produced.

## How to read it

Part I explains what you are building and why it is shaped the way it is. If you
only want to get BNK running, skim [Chapter 2](02-how-it-works.md) for the
picture of the sync pipeline and go straight to Part II.

Part II is the walk-through: sign in, wire Argo CD to the Git repository,
describe the workspace, press **Sync**, read the logs, verify. Part III covers
the three cluster sizes F5's sizing guide describes and how each one is
expressed in a few lines of values. Part IV tears BNK down again — both ways.
Part V is for the day after: re-syncs, upgrades, what to do when a gate fails.

The reference section documents every chart value, every hook Job and the RBAC
they need, and the two appendices cover building the Argo CD hub VSI in the
IBM Cloud fabric and refreshing the screenshots.

## Conventions

- `code` is something you type, a file name, or an exact string on screen.
- **Bold** in a step is the control to click in the Argo CD UI.
- Commands are shown for a Linux shell; the Argo CD CLI is used in `--core`
  mode against the cluster Argo CD runs in, which needs no API server login.
- Secrets are never written in Git. Where a value is shown as `••••••••` the
  screenshot scrubber replaced it; where you see `…` you supply your own.

The companion repository is
[github.com/jgruberf5/roksbnk-argo-cd](https://github.com/jgruberf5/roksbnk-argo-cd).
The tool that runs inside the hook Jobs, and the book that documents it in
depth, is [roksbnkctl](https://jgruberf5.github.io/roksbnkctl/book/).
