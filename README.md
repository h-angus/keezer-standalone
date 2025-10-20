sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/h-angus/keezer-standalone/main/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh'


sudo sh -c '
  set -e
  # Stop/remove all containers
  docker ps -aq | xargs -r docker rm -f
  # Remove all volumes
  docker volume ls -q | xargs -r docker volume rm
  # Remove non-default networks
  docker network ls -q | grep -vE "(^| )?(bridge|host|none)($| )" | xargs -r docker network rm
  # Prune everything else
  docker system prune -af
  # Remove the keezer project directory
  rm -rf /opt/keezer-base
'
