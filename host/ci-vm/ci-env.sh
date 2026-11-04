# shared settings (sourced). Everything lives in the invoking user's home; nothing needs sudo.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
CI_HOME=${CI_HOME:-$HOME/eve-ci}
CI_PROFILE=eveci
export DOCKER_HOST="unix://$HOME/.colima/$CI_PROFILE/docker.sock"
CI_IMAGE=eve-ci-runner:1
OWNER=gun025bba
# repo:slots  (a slot = one runner registration = one job at a time)
CI_REPOS="${CI_REPOS:-eve-serving:2 eve-web:1}"
CI_JOB_MEMORY=${CI_JOB_MEMORY:-3g}
CI_JOB_CPUS=${CI_JOB_CPUS:-2}
