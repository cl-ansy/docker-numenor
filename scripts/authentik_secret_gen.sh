openssl rand -base64 36 | tr -d '\n' | sudo tee postgres_default_password
echo "authentik_db_user" | sudo tee authentik_postgresql_user
openssl rand -base64 60 | tr -d '\n' | sudo tee authentik_postgresql_password
openssl rand -base64 60 | tr -d '\n' | sudo tee authentik_secret_key
