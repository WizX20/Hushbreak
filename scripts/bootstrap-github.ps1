<#
.SYNOPSIS
Applies the GitHub repository settings this project relies on: merge policy, features,
topics, labels and the `main` ruleset. Idempotent - run it again after changing anything here.

.DESCRIPTION
Runs the GitHub CLI through `git gh` (the WizX20 routing from .gitconfig, see DEVGUIDE.md),
so `task setup` must have been done in this clone. Creating the repository itself is a
one-off (`git gh repo create WizX20/Hushbreak --public --source . --push`); this script
does everything after that. The release token secret cannot be set here: create a
fine-grained PAT with Contents: read/write on this repo and store it as
HUSHBREAK_RELEASE_TOKEN under Settings > Secrets and variables > Actions.

.PARAMETER Repo
owner/name of the repository. Defaults to WizX20/Hushbreak.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'WizX20/Hushbreak'
)
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([string[]]$GhArgs, $Body)
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $out = $json | git gh api @GhArgs --input -
    }
    else {
        $out = git gh api @GhArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "gh api $($GhArgs -join ' ') failed" }
    return $out
}

Write-Host "== repository settings ($Repo)" -ForegroundColor Cyan
Invoke-Gh @('-X', 'PATCH', "repos/$Repo") @{
    description                 = 'VLC add-on that hushes the ad breaks on Triton/StreamTheWorld radio streams such as KINK'
    homepage                    = "https://github.com/$Repo"
    has_issues                  = $true
    has_projects                = $false
    has_wiki                    = $false
    has_discussions             = $true
    allow_squash_merge          = $true
    allow_merge_commit          = $false
    allow_rebase_merge          = $false
    delete_branch_on_merge      = $true
    allow_auto_merge            = $false
    squash_merge_commit_title   = 'COMMIT_OR_PR_TITLE'
    squash_merge_commit_message = 'COMMIT_MESSAGES'
    web_commit_signoff_required = $false
} | Out-Null
Invoke-Gh @('-X', 'PUT', "repos/$Repo/topics") @{ names = @('vlc', 'vlc-extension', 'lua', 'radio', 'ad-blocker', 'triton-digital', 'streamtheworld', 'kink') } | Out-Null
Write-Host '   settings + topics applied'

Write-Host '== labels' -ForegroundColor Cyan
$labels = @(
    @{ name = 'accessibility'; color = 'f143ab'; description = 'Barrier affecting people with disabilities' },
    @{ name = 'bug'; color = 'd73a4a'; description = "Something isn't working" },
    @{ name = 'ci'; color = '0e8a16'; description = 'Workflows, actions, pipeline' },
    @{ name = 'dependencies'; color = '0366d6'; description = 'Dependency bumps' },
    @{ name = 'documentation'; color = '0075ca'; description = 'Improvements or additions to documentation' },
    @{ name = 'duplicate'; color = 'cfd3d7'; description = 'This issue or pull request already exists' },
    @{ name = 'enhancement'; color = 'a2eeef'; description = 'New feature or request' },
    @{ name = 'good first issue'; color = '7057ff'; description = 'Good for newcomers' },
    @{ name = 'help wanted'; color = '008672'; description = 'Extra attention is needed' },
    @{ name = 'invalid'; color = 'e4e669'; description = "This doesn't seem right" },
    @{ name = 'maintenance'; color = '0e8a16'; description = 'Housekeeping with a date: tokens, pipelines, dependencies' },
    @{ name = 'question'; color = 'd876e3'; description = 'Further information is requested' },
    @{ name = 'station'; color = 'fbca04'; description = 'Support for a specific radio station or stream provider' },
    @{ name = 'status/in-progress'; color = '1d76db'; description = 'Being worked on: a branch or PR exists' },
    @{ name = 'status/planned'; color = 'bfd4f2'; description = 'Accepted and on the list; no branch yet' },
    @{ name = 'triage'; color = 'd4c5f9'; description = 'Needs a first look: not yet a bug or a feature' },
    @{ name = 'wontfix'; color = 'ffffff'; description = 'This will not be worked on' }
)
$existing = @(Invoke-Gh @('--paginate', "repos/$Repo/labels", '--jq', 'map(.name) | .[]'))
foreach ($label in $labels) {
    if ($existing -contains $label.name) {
        $encoded = [uri]::EscapeDataString($label.name)
        Invoke-Gh @('-X', 'PATCH', "repos/$Repo/labels/$encoded") @{ color = $label.color; description = $label.description } | Out-Null
        Write-Host "   updated  $($label.name)"
    }
    else {
        Invoke-Gh @('-X', 'POST', "repos/$Repo/labels") $label | Out-Null
        Write-Host "   created  $($label.name)"
    }
}

Write-Host '== ruleset main' -ForegroundColor Cyan
# Same shape as PSWorktree: main is PR-only with squash merges, CI must be green, no
# deletion or force-push; repository admins may bypass (the release workflow pushes with
# an admin token).
$ruleset = @{
    name         = 'main'
    target       = 'branch'
    enforcement  = 'active'
    conditions   = @{ ref_name = @{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
    bypass_actors = @(@{ actor_id = 5; actor_type = 'RepositoryRole'; bypass_mode = 'always' })
    rules        = @(
        @{ type = 'deletion' },
        @{ type = 'non_fast_forward' },
        @{ type = 'pull_request'; parameters = @{
                allowed_merge_methods                           = @('squash')
                dismiss_stale_reviews_on_push                   = $false
                require_code_owner_review                       = $false
                require_extra_approval_for_unattributed_changes = $true
                require_last_push_approval                      = $false
                required_approving_review_count                 = 0
                required_review_thread_resolution               = $false
            }
        },
        @{ type = 'required_status_checks'; parameters = @{
                do_not_enforce_on_create             = $true
                strict_required_status_checks_policy = $true
                required_status_checks               = @(
                    @{ context = 'lint + test (Lua 5.1)'; integration_id = 15368 },
                    @{ context = 'pack release zip'; integration_id = 15368 },
                    @{ context = 'release token expiry'; integration_id = 15368 }
                )
            }
        }
    )
}
$rulesets = Invoke-Gh @("repos/$Repo/rulesets") | ConvertFrom-Json
$current = $rulesets | Where-Object name -eq 'main' | Select-Object -First 1
if ($current) {
    Invoke-Gh @('-X', 'PUT', "repos/$Repo/rulesets/$($current.id)") $ruleset | Out-Null
    Write-Host "   updated ruleset $($current.id)"
}
else {
    Invoke-Gh @('-X', 'POST', "repos/$Repo/rulesets") $ruleset | Out-Null
    Write-Host '   created ruleset'
}

Write-Host ''
Write-Host 'Done. Still manual: the HUSHBREAK_RELEASE_TOKEN secret (fine-grained PAT, Contents read/write on this repo).' -ForegroundColor Yellow
