#!/bin/bash
# Keycloak travel-platform realm setup script
# Run this inside the Keycloak container:
# docker exec -it keycloak-service-keycloak-1 bash /opt/keycloak/scripts/setup-realm.sh

KEYCLOAK_URL="http://localhost:8080"
ADMIN_USER="qtran1018"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASS:-CHANGE_ME}"  # set env var or edit here

echo "=== Authenticating ==="
/opt/keycloak/bin/kcadm.sh config credentials \
  --server $KEYCLOAK_URL \
  --realm master \
  --user $ADMIN_USER \
  --password $ADMIN_PASS

echo "=== Creating travel-platform realm ==="
/opt/keycloak/bin/kcadm.sh create realms \
  -s realm=travel-platform \
  -s enabled=true \
  -s registrationAllowed=true \
  -s loginWithEmailAllowed=true \
  -s duplicateEmailsAllowed=false \
  -s resetPasswordAllowed=true \
  -s editUsernameAllowed=false

echo "=== Creating splitpush client ==="
/opt/keycloak/bin/kcadm.sh create clients -r travel-platform \
  -s clientId=splitpush \
  -s enabled=true \
  -s publicClient=false \
  -s secret=splitpush-secret \
  -s 'redirectUris=["https://splitpush.quangntran.com/*","http://localhost:8080/*"]' \
  -s 'webOrigins=["https://splitpush.quangntran.com","http://localhost:8080"]' \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=true

echo "=== Creating travelbin-frontend client ==="
/opt/keycloak/bin/kcadm.sh create clients -r travel-platform \
  -s clientId=travelbin-frontend \
  -s enabled=true \
  -s publicClient=true \
  -s 'redirectUris=["https://travelbin.quangntran.com/*","http://localhost:3001/*","http://localhost:3000/*","http://localhost:5173/*"]' \
  -s 'webOrigins=["https://travelbin.quangntran.com","http://localhost:3001","http://localhost:5173"]' \
  -s standardFlowEnabled=true \
  -s attributes='{"pkce.code.challenge.method":"S256"}'

echo "=== Creating itinerary-agent client ==="
/opt/keycloak/bin/kcadm.sh create clients -r travel-platform \
  -s clientId=itinerary-agent \
  -s enabled=true \
  -s publicClient=true \
  -s 'redirectUris=["https://agent.quangntran.com/*","http://localhost:3010/*","http://localhost:3000/*"]' \
  -s 'webOrigins=["https://agent.quangntran.com","http://localhost:3010","http://localhost:3000"]' \
  -s standardFlowEnabled=true \
  -s attributes='{"pkce.code.challenge.method":"S256"}'

echo "=== Enabling direct access grants on travelbin-frontend (dev/testing only) ==="
CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r travel-platform -q clientId=travelbin-frontend --fields id --format csv --noquotes)
/opt/keycloak/bin/kcadm.sh update clients/$CLIENT_ID -r travel-platform \
  -s directAccessGrantsEnabled=true

echo "=== Creating test user ==="
/opt/keycloak/bin/kcadm.sh create users -r travel-platform \
  -s username=testuser \
  -s email=test@example.com \
  -s enabled=true \
  -s emailVerified=true

USER_ID=$(/opt/keycloak/bin/kcadm.sh get users -r travel-platform -q username=testuser --fields id --format csv --noquotes)
/opt/keycloak/bin/kcadm.sh set-password -r travel-platform \
  --userid $USER_ID \
  --new-password password123 \
  --temporary false

echo "=== Setting login theme ==="
/opt/keycloak/bin/kcadm.sh update realms/travel-platform \
  -s 'loginTheme=travel-platform'

echo "=== Done! travel-platform realm is ready ==="
echo "Test user: test@example.com / password123 (username: testuser)"
echo "Remember to set the Splitpush client secret in your app config: splitpush-secret"
