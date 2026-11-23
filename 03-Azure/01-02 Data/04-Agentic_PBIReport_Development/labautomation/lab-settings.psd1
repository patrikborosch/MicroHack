@{
    # Nonsecret source defaults. Scope and identities always come from the platform.
    EventId = 'agentic-pbi-v1'
    DefaultRegion = 'switzerlandnorth'
    VmSize = 'Standard_D4s_v5'
    Image = @{ publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'; sku = '2022-datacenter-g2' }
    OsDiskSizeGB = 128
    BastionScaleUnits = 2
    SourceRef = '679f03ec391f2b8adfac4b1fdf58878f8674c272'
    PackagePolicy = 'latest-stable-at-provisioning'
}
