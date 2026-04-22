#!/bin/bash
set -e

# Install Node.js 20 and dependencies
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
yum install -y nodejs git jq

# Read database credentials from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString \
  --output text)

DB_USER=$(echo "$SECRET" | jq -r '.username')
DB_PASS=$(echo "$SECRET" | jq -r '.password' | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))")
DB_NAME=$(echo "$SECRET" | jq -r '.dbname')

# Resolve the RDS endpoint via AWS CLI (avoids hardcoding it in user-data)
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${project}-postgres" \
  --region "${aws_region}" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

# Clone the application
git clone https://github.com/wb-platform-engineering-lab/cloud-migration-lab-aws.git /app
cd /app/phase-2-lift-and-shift/orderflow
npm install --production

# Write the environment file
cat > /app/phase-2-lift-and-shift/orderflow/.env <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgres://$DB_USER:$DB_PASS@$RDS_ENDPOINT:5432/$DB_NAME?sslmode=no-verify
REDIS_URL=redis://${redis_endpoint}:6379
SESSION_SECRET=$(openssl rand -hex 32)
EOF

# Run database migrations
npm run migrate

# Install as a systemd service
cat > /etc/systemd/system/orderflow.service <<EOF
[Unit]
Description=OrderFlow
After=network.target

[Service]
WorkingDirectory=/app/phase-2-lift-and-shift/orderflow
EnvironmentFile=/app/phase-2-lift-and-shift/orderflow/.env
ExecStart=/usr/bin/node src/app.js
Restart=always
RestartSec=5
User=ec2-user

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable orderflow
systemctl start orderflow
