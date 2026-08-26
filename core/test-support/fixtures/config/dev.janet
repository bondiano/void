# Profile-specific config as code: the last form is the config value.
# The active profile is visible as (dyn :void/profile).
{:database {:port 5433}
 :app {:profile-seen (dyn :void/profile)}}
