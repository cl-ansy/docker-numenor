# Add to ~/.bashrc:
#   export DOCKERDIR="$HOME/docker-numenor"
#   source "$DOCKERDIR/shared/.bash_aliases"
#
# DOCKERDIR must match the value in .env - the compose files resolve every path
# from it. See runbooks/access.md.

: "${DOCKERDIR:=$HOME/docker-numenor}"

# docker
alias dps='sudo docker ps -a'
alias dprune='sudo docker system prune'

# docker compose
alias dcmain='sudo docker compose -f "$DOCKERDIR/docker-compose-main.yml"'
alias dcrun='dcmain run'
alias dclogs='dcmain logs -tf --tail="50"'
alias dcup='dcmain up -d --build --remove-orphans'
alias dcdown='dcmain down --remove-orphans'
alias dcstop='dcmain stop'
alias dcrestart='dcmain restart '
alias dcstart='dcmain start '
alias dcpull='dcmain pull'
alias dcconfig='dcmain config'

# logs
alias traefiklogs='tail -f "$DOCKERDIR/logs/traefik/traefik.log"'
alias accesslogs='tail -f "$DOCKERDIR/logs/traefik/access.log"'

# where things are
alias cddocker='cd "$DOCKERDIR"'
alias runbook='${PAGER:-less} "$DOCKERDIR/runbooks/access.md"'
