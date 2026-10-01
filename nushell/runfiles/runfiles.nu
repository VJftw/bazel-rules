# Runfiles lookup for Nushell scripts run by rules_nushell's launchers (a
# nu_binary/nu_test, or another ruleset's nu_launcher - see //:nu.bzl).
#
# Those launchers export RUNFILES_DIR and/or RUNFILES_MANIFEST_FILE and put
# this module on the include path, so a script can:
#
#     use runfiles.nu
#     open (runfiles rlocation "_main/path/to/data.json")

# Resolves `path` - "<repo>/<path within that repo>", e.g.
# "_main/app/name.txt" for a file in the main repository - to its real path.
export def rlocation [path: string] {
    let dir = ($env.RUNFILES_DIR? | default "")
    if $dir != "" {
        let candidate = ($dir | path join $path)
        if ($candidate | path exists) {
            return $candidate
        }
    }

    let manifest = ($env.RUNFILES_MANIFEST_FILE? | default "")
    if $manifest != "" {
        let prefix = $"($path) "
        let hit = (open --raw $manifest | lines | where {|line| $line starts-with $prefix } | first 1)
        if ($hit | is-not-empty) {
            return ($hit.0 | str substring ($prefix | str length)..)
        }
    }

    error make {msg: $"($path) not found in runfiles \(RUNFILES_DIR: '($dir)', RUNFILES_MANIFEST_FILE: '($manifest)'\)"}
}
