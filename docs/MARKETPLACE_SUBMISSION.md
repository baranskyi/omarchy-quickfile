# QuickFile marketplace submission draft

Status: **ready for owner confirmation; not submitted**. The repository-root
`preview.png` is prepared for final validation. The marketplace accepts up to
50 MB and 40 megapixels and generates its own optimized card and detail images.
Before submission, the owner must directly approve the title and exact body and
confirm that every checklist statement, including preview-asset ownership, is
true.

## Proposed listing

- Title: `[Plugin]: QuickFile`
- Repository: `https://github.com/baranskyi/omarchy-quickfile`
- Category: `Productivity`
- Tags: `quickshell, system, bar`
- Suggested missing tag: `file-manager`
- Permanent plugin ID: `m0sthatedman.quickfile`

## Exact issue body

Copy only the contents of this code block into the marketplace submission
issue. Keep every heading and checklist item in this order.

```markdown
### Repository URL

https://github.com/baranskyi/omarchy-quickfile

### Category

Productivity

### Tags

quickshell, system, bar

### Suggest a missing tag

file-manager

### Maintainer notes

QuickFile is a native Omarchy Quattro file manager sidebar with event-driven filesystem updates, bounded recursive operations, Trash-backed Undo, inline previews, Quick Nav, Git context, and project-knowledge discovery. It makes no network requests, installs no packages or services, requires no elevated privileges, and passes the repository's backend, watcher, QML, and Omarchy manifest validation suites.

### Submission checklist
- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

## Submission command — do not run before owner approval

After the screenshot is committed, all checks pass on the exact remote commit,
and the owner directly approves submission, create the issue with:

```bash
gh issue create \
  --repo omacom/omarchy-plugin-marketplace \
  --title "[Plugin]: QuickFile" \
  --body-file /tmp/omarchy-plugin-submission.md
```

The `/tmp/omarchy-plugin-submission.md` file must contain only the exact issue
body above. Opening the issue triggers marketplace validation; it does not
publish the plugin immediately.
