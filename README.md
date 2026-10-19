# gh-actions-version.nvim

Neovim plugin that displays resolved GitHub Actions versions as virtual text.

When editing workflow files, it resolves:
- **SHA refs** → tag name (e.g. `actions/checkout@b4ffde6...` → `v4.2.1`)
- **Short version tags** → full semver (e.g. `actions/checkout@v4` → `v4.2.1`)

## Requirements

- Neovim >= 0.10
- [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "rawnly/gh-actions-version.nvim",
  opts = {},
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "rawnly/gh-actions-version.nvim",
  config = function()
    require("gh-actions-version").setup()
  end,
}
```

## Configuration

```lua
require("gh-actions-version").setup({
  hl_group = "Comment",            -- virtual text highlight
  lint = true,                     -- publish diagnostics
  store_path = vim.fn.stdpath("data") .. "/gh-actions-version/approved.json",
  trusted_orgs = {},               -- owners whose actions allow ANY full SHA
  trust_current_org = true,        -- also trust owner of the repo's `origin` remote
  verify_sha = true,               -- check via `gh` that pinned SHAs exist in their repo
  auto_learn = false,              -- approve pinned SHAs automatically on save
})
```

## Linting (org pin-hash policy)

Diagnostics on `uses:` refs in `.github/workflows/` and `.github/actions/`:

| Severity | Condition |
| --- | --- |
| Error | `owner/repo@sha` is not approved and `owner` is not trusted |
| Warn | pinned SHA doesn't exist in `owner/repo` (404 from GitHub; auth/network errors are ignored) |
| Warn | `# vX` comment differs from the approved tag for that SHA |

Only refs pinned to a full 40-char SHA are linted; tags/branches (`@v4`, `@main`) are ignored (use actionlint / your LSP for that). Local (`./`) and `docker://` uses are ignored. Owners are trusted when listed in
`trusted_orgs` or equal to the `origin` owner of the current repo.

Approved entries live in one global JSON file (`store_path`), keyed by
`owner/repo` -> SHA -> `{ tag }`. Edit it by hand or grow it with the commands below.

## Commands

`:GhActionsVersion [subcommand]` (tab-completes; defaults to `check`)

| Subcommand | Description |
| --- | --- |
| `check` | Resolve versions and lint the current buffer |
| `clear` | Clear annotations, diagnostics and cache |
| `approve[!]` | Approve pinned action on cursor line (`!` = whole buffer) |
| `learn` | Approve every pinned action in the current repo's workflows |
| `fix` | Pick an approved SHA for the line, or pin its current ref via GitHub |
| `store` | Open the approved store |

### Example

Given a workflow file:

```yaml
steps:
  - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
  - uses: actions/setup-node@v4
```

The plugin will display:

```yaml
steps:
  - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  v4.1.1
  - uses: actions/setup-node@v4  v4.2.0
```

## License

MIT
