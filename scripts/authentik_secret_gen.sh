echo "$AUTHENTIK_POSTGRESQL__USER" | sudo tee authentik_postgresql_user
openssl rand -base64 60 | tr -d '\n' | sudo tee authentik_postgresql_password
openssl rand -base64 60 | tr -d '\n' | sudo tee authentik_secret_key
