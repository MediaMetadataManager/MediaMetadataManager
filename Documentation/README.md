# Media Metadata Manager — Documentation

This folder holds the documentation set for **Media Metadata Manager (M3)**. Each manual is provided as Markdown (readable on GitHub), PDF (for reading and printing) and Word (for editing).

| Document | For | Markdown | PDF | Word |
|---|---|---|---|---|
| **Getting Started Guide** — install to first finished file in ten minutes | New users | [md](Getting-Started.md) | [pdf](Getting-Started.pdf) | [docx](Getting-Started.docx) |
| **User Guide** — every window, setting and task | Users | [md](User-Guide.md) | [pdf](User-Guide.pdf) | [docx](User-Guide.docx) |
| **Design and Project Manual** — architecture, workflows, history, roadmap (internal) | Maintainers | [md](Internal/Design-and-Project-Manual.md) | [pdf](Internal/Design-and-Project-Manual.pdf) | [docx](Internal/Design-and-Project-Manual.docx) |

## Folder layout

| Folder | Contents |
|---|---|
| `Internal/` | Maintainer documentation. Review before publishing publicly: it names optional plugins and records development practice. |
| `images/` | Figures used by the manuals. `images/src/` holds the Graphviz and matplotlib sources so they can be regenerated. |
| `diagrams/` | Editable draw.io source of the Media Intake flowchart (`M3-intake-pipeline.drawio`). Open it with diagrams.net or the draw.io desktop app. |

## Uploading selectively to GitHub

The *Getting Started* and *User Guide* files, plus `images/`, are written to be safe for public upload. To publish only those, add `Documentation/Internal/` to `.gitignore` (or simply do not `git add` it).

## Keeping the documents current

The Design and Project Manual is a living document. Its first section explains how to update the change log, phase table, open-items list and decisions log. When a feature changes behavior, update the User Guide and, if the first-run steps change, the Getting Started Guide. Re-export the PDF and Word copies from the Markdown at each milestone so all three formats stay in step.
