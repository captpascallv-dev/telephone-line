@{
    ProtocolVersion = 'telephone-line-codex-app-server-compatibility-catalog-v1'
    ServiceTier = 'default'
    SurfaceFiles = @(
        'ServerNotification.json'
        'v2/ThreadStartParams.json'
        'v2/ThreadStartResponse.json'
        'v2/ThreadResumeParams.json'
        'v2/ThreadResumeResponse.json'
        'v2/ThreadReadParams.json'
        'v2/ThreadReadResponse.json'
        'v2/TurnStartParams.json'
        'v2/TurnStartResponse.json'
        'v2/ThreadStatusChangedNotification.json'
        'v2/ServerRequestResolvedNotification.json'
        'v2/TurnCompletedNotification.json'
    )
    Entries = @(
        @{
            CodexVersion = 'codex-cli 0.147.0'
            SchemaFileCount = 285
            SchemaBytes = 2925973
            SchemaFingerprint = '4fdd2ab6f7d30fb53d8f9e17e3fc56fca4eb82548f4de57d2edb258acddb76c9'
            SurfaceFileCount = 12
            SurfaceBytes = 528014
            SurfaceFingerprint = '846d7218b8235c28ba56c5aaa280eb47e1555047a4c7613b858090f0faca4b3c'
            AdapterRule = 'app-server-v0147'
            ProjectIdMode = 'absent'
            NotificationEnvelopeMode = 'strict-v0147'
        }
        @{
            CodexVersion = 'codex-cli 0.149.0'
            SchemaFileCount = 291
            SchemaBytes = 3023451
            SchemaFingerprint = '72f39b627e1c31d8d2ea434dd3c1a0881757a91cf986e00d0550e32f5085287a'
            SurfaceFileCount = 12
            SurfaceBytes = 544489
            SurfaceFingerprint = '13f11ff8c2cc0767abdc6daafa6be5a0d33968e252c46694aa0bdc427b1b7083'
            AdapterRule = 'app-server-v0149'
            ProjectIdMode = 'null-only'
            NotificationEnvelopeMode = 'emitted-at-ms-optional'
        }
        @{
            CodexVersion = 'codex-cli 0.149.1'
            SchemaFileCount = 291
            SchemaBytes = 3023451
            SchemaFingerprint = '72f39b627e1c31d8d2ea434dd3c1a0881757a91cf986e00d0550e32f5085287a'
            SurfaceFileCount = 12
            SurfaceBytes = 544489
            SurfaceFingerprint = '13f11ff8c2cc0767abdc6daafa6be5a0d33968e252c46694aa0bdc427b1b7083'
            AdapterRule = 'app-server-v0149'
            ProjectIdMode = 'null-only'
            NotificationEnvelopeMode = 'emitted-at-ms-optional'
        }
        # TEST_RUNTIME_ENTRY_INSERTION_POINT
    )
}
