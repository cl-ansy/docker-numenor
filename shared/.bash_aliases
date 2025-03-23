# source "$HOME/docker-numenor/shared/.bash_aliases"

# docker
alias dps='sudo docker ps -a'
alias dprune='sudo docker system prune'

# docker compose
alias dcmain='sudo docker compose -f /home/chris/docker-numenor/docker-compose-main.yml'
alias dcrun='dcmain run'
alias dclogs='dcmain logs -tf --tail="50"'
alias dcup='dcmain up -d --build --remove-orphans'
alias dcdown='dcmain down --remove-orphans'
alias dcstop='dcmain stop'
alias dcrestart='dcmain restart '
alias dcstart='dcmain start '
alias dcpull='dcmain pull'

# logs
alias traefiklogs='tail -f /home/chris/docker/logs/traefik/traefik.log'
