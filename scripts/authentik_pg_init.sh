$POSTGRES_USER=""
$AUTHENTIK_DB_USER=""
$AUTHENTIK_DB_PASSWORD=""

# Create authentik db
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "CREATE DATABASE authentik;"
# Create $AUTHENTIK_DB_USER
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "CREATE USER $AUTHENTIK_DB_USER WITH PASSWORD '$AUTHENTIK_DB_PASSWORD';"
# Give $AUTHENTIK_DB_USER all privs on authentik db
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "GRANT ALL PRIVILEGES ON DATABASE authentik TO $AUTHENTIK_DB_USER;"
# Change ownership and grant schema permissions of authentik database to $AUTHENTIK_DB_USER
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "ALTER DATABASE authentik OWNER TO $AUTHENTIK_DB_USER;"
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $AUTHENTIK_DB_USER;"
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $AUTHENTIK_DB_USER;"
sudo docker exec -it postgres psql -U $POSTGRES_USER -c "GRANT CREATE ON SCHEMA public TO $AUTHENTIK_DB_USER;"
