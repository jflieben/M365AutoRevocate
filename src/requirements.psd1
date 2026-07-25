# Managed dependencies are intentionally DISABLED (see host.json).
#
# M365AutoRevocate talks to Microsoft Graph and Azure Table storage over raw
# REST using the Function App's managed identity. It deliberately avoids the
# Microsoft.Graph and Az.* modules so that cold starts stay fast and there is
# no supply chain to patch. Do not add modules here without also enabling
# managedDependency in host.json.
@{
}
