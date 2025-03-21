# source "$HOME/docker-numenor/shared/.bash_aliases"

# docker
alias dps='sudo docker ps -a'
alias dprune='sudo docker system prune'

# docker compose
alias dcrun='sudo docker compose -f /home/chris/docker-numenor/docker-compose-main.yml'
alias dclogs='dcrun logs -tf --tail="50"'
alias dcup='dcrun up -d --build --remove-orphans'
alias dcdown='dcrun down --remove-orphans'
alias dcstop='dcrun stop'
alias dcrestart='dcrun restart '
alias dcstart='dcrun start '
alias dcpull='dcrun pull'

# logs
alias traefiklogs='tail -f /home/chris/docker/logs/traefik/traefik.log'
