apiVersion: syncagent.kcp.io/v1alpha1
kind: PublishedResource
metadata:
  name: applications
spec:
  resource:
    apiGroup: platform.internal.demo
    versions:
      - v1alpha1
    kind: Application
  naming:
    name: "{{ .Object.metadata.name }}"
    namespace: demo
  projection:
    group: applications.demo.kcp.io
  related:
    - identifier: database
      origin: service
      group: database.internal.demo
      version: v1alpha1
      resource: databases
      identityHash: __DATABASE_IDENTITY_HASH__
      projection:
        group: databases.demo.kcp.io
      object:
        reference:
          path: spec.databaseName
      syncStatus: true
      syncStatusOrigin: kcp
      watch:
        byOwner: {}
