{
  "realm": "lab",
  "enabled": true,
  "displayName": "LAB.TEST",
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
  "authenticationFlows": [
    {
      "id": "browser",
      "alias": "browser",
      "description": "${browserFlow}",
      "providerId": "basic-flow",
      "topLevel": true,
      "builtIn": true,
      "authenticationExecutions": [
        {
          "authenticator": "auth-cookie",
          "authenticatorFlow": false,
          "requirement": "ALTERNATIVE",
          "priority": 10,
          "authenticatorConfig": "Cookie provider"
        },
        {
          "authenticator": "auth-spnego",
          "authenticatorFlow": false,
          "requirement": "ALTERNATIVE",
          "priority": 20,
          "authenticatorConfig": "Kerberos"
        },
        {
          "authenticator": "identity-provider-redirector",
          "authenticatorFlow": false,
          "requirement": "ALTERNATIVE",
          "priority": 30,
          "authenticatorConfig": "Identity Provider Redirector"
        },
        {
          "authenticatorFlow": true,
          "requirement": "ALTERNATIVE",
          "priority": 40,
          "flowAlias": "forms"
        }
      ]
    },
    {
      "id": "forms",
      "alias": "forms",
      "description": "${formsFlow}",
      "providerId": "basic-flow",
      "topLevel": false,
      "builtIn": true,
      "authenticationExecutions": [
        {
          "authenticator": "auth-username-password-form",
          "authenticatorFlow": false,
          "requirement": "REQUIRED",
          "priority": 10
        },
        {
          "authenticator": "auth-otp-form",
          "authenticatorFlow": false,
          "requirement": "DISABLED",
          "priority": 20
        }
      ]
    }
  ],
  "authenticatorConfig": [
    {
      "id": "Cookie provider",
      "alias": "Cookie provider",
      "config": {
        "cookie.max.age": "300"
      }
    },
    {
      "id": "Identity Provider Redirector",
      "alias": "Identity Provider Redirector",
      "config": {
        "defaultProvider": ""
      }
    },
    {
      "id": "Kerberos",
      "alias": "Kerberos",
      "config": {
        "debug": "false",
        "keyTab": "FILE:/keytabs/keycloak.keytab",
        "kerberosRealm": "${REALM}",
        "serverPrincipal": "HTTP/${KEYCLOAK_HOST}",
        "allowEmptyAuth": "false"
      }
    }
  ],
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
          "searchScope": ["1"],
          "importEnabled": ["false"],
          "syncPeriod": ["-1"],
          "batchSizeForSync": ["1000"],
          "priority": ["0"],
          "connectionPooling": ["true"],
          "pagination": ["true"],
          "allowPasswordAuthentication": ["true"],
          "allowKerberosAuthentication": ["true"],
          "kerberosRealm": ["${REALM}"],
          "keyTab": ["FILE:/keytabs/keycloak.keytab"],
          "serverPrincipal": ["HTTP/${KEYCLOAK_HOST}"],
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
  }
}
