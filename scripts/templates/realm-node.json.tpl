{
  "realm": "${KC_REALM}",
  "enabled": true,
  "displayName": "${NODE_LABEL}",
  "sslRequired": "none",
  "registrationAllowed": false,
  "loginWithEmailAllowed": false,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "editUsernameAllowed": false,
  "bruteForceProtected": false,
  "rememberMe": false,
  "verifyEmail": false,
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "accessCodeLifespan": 60,
  "accessCodeLifespanUserAction": 300,
  "accessCodeLifespanLogin": 1800,
  "actionTokenGeneratedByAdminLifespan": 43200,
  "actionTokenGeneratedByUserLifespan": 300,
  "internationalizationEnabled": false,
  "eventsEnabled": false,
  "adminEventsEnabled": false,
  "components": {
    "org.keycloak.storage.UserStorageProvider": [
      {
        "id": "lab-ldap",
        "name": "lab-ldap",
        "providerId": "ldap",
        "config": {
          "vendor": ["other"],
          "connectionUrl": ["ldap://${LDAP_HOST}:389"],
          "bindDn": ["cn=admin,${DC_BASE}"],
          "bindCredential": ["${LDAP_ADMIN_PASSWORD}"],
          "editMode": ["READ_ONLY"],
          "usernameLDAPAttribute": ["uid"],
          "rdnLDAPAttribute": ["uid"],
          "uuidLDAPAttribute": ["entryUUID"],
          "usersDn": ["ou=people,${DC_BASE}"],
          "userObjectClass": ["inetOrgPerson"],
          "searchScope": ["2"],
          "importEnabled": ["false"],
          "syncPeriod": ["-1"],
          "batchSizeForSync": ["1000"],
          "priority": ["0"],
          "connectionPooling": ["true"],
          "pagination": ["true"],
          "allowPasswordAuthentication": ["true"],
          "allowKerberosAuthentication": ["false"],
          "useTruststoreSpi": ["ldapsOnly"],
          "debug": ["false"],
          "cachePolicy": ["DEFAULT"]
        },
        "subComponents": {
          "org.keycloak.storage.ldap.mappers.LDAPStorageMapper": [
            {
              "name": "username",
              "providerId": "user-attribute-ldap-mapper",
              "config": {
                "user.model.attribute": ["username"],
                "ldap.attribute": ["uid"],
                "read.only": ["true"],
                "always.read.value.from.ldap": ["false"],
                "is.mandatory.in.ldap": ["true"]
              }
            },
            {
              "name": "first name",
              "providerId": "user-attribute-ldap-mapper",
              "config": {
                "user.model.attribute": ["firstName"],
                "ldap.attribute": ["cn"],
                "read.only": ["true"],
                "always.read.value.from.ldap": ["true"],
                "is.mandatory.in.ldap": ["true"]
              }
            },
            {
              "name": "last name",
              "providerId": "user-attribute-ldap-mapper",
              "config": {
                "user.model.attribute": ["lastName"],
                "ldap.attribute": ["sn"],
                "read.only": ["true"],
                "always.read.value.from.ldap": ["true"],
                "is.mandatory.in.ldap": ["true"]
              }
            },
            {
              "name": "email",
              "providerId": "user-attribute-ldap-mapper",
              "config": {
                "user.model.attribute": ["email"],
                "ldap.attribute": ["mail"],
                "read.only": ["true"],
                "always.read.value.from.ldap": ["false"],
                "is.mandatory.in.ldap": ["false"]
              }
            }
          ]
        }
      }
    ]
  },
  "clients": [
    {
      "clientId": "portal",
      "name": "Портал (${NODE_LABEL})",
      "enabled": true,
      "publicClient": false,
      "protocol": "openid-connect",
      "secret": "${CLIENT_SECRET}",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": [
        "${PUBLIC_WEB_BASE}/callback",
        "http://${WEB_HOST}/callback"
      ],
      "webOrigins": ["+"],
      "attributes": {
        "post.logout.redirect.uris": "+"
      }
    }
  ]
}
