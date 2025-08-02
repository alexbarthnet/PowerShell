function Format-XmlEmptyNodes {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [Xml.XmlNode]$XmlNode,
        [Parameter(Position = 1)][ValidateSet('Compressed', 'Expanded')]
        [string]$Style = 'Compressed'
    )

    # loop through child nodes of provided XML node
    foreach ($ChildNode in $XmlNode.ChildNodes) {
        # if child node has child nodes...
        if ($ChildNode.ChildNodes.Count) {
            # recursively loop through child nodes of child node
            Format-XmlEmptyNode -XmlNode $ChildNode
        }
        # if child node has no child nodes and inner XML is empty...
        elseif ([string]::IsNullOrEmpty($ChildNode.InnerXml)) {
            # if style is...
            switch ($Style) {
                'Compressed' {
                    # set IsEmpty to true
                    $Element.IsEmpty = $true
                }
                'Expanded' {
                    # set IsEmpty to false
                    $Element.IsEmpty = $false
                }
            }
        }
    }
}
