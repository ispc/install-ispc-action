# SPDX-License-Identifier: Apache-2.0
# Sourced by bash only if the action fails to clear BASH_ENV/ENV (TRANSITION.md C7).
echo "::error::hostile-env.sh was sourced by the action"
# shellcheck disable=SC2123 # Breaking PATH is the point.
PATH=/nonexistent
cd /
exit 3
