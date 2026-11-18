/// Minimal hand-authored USD device: a body box and a screen quad whose
/// materials carry the names the render definitions address.
enum RealityKitRenderFixtures {
    static let deviceUSDA = """
    #usda 1.0
    (
        defaultPrim = "Device"
        upAxis = "Y"
        metersPerUnit = 1
    )

    def Xform "Device"
    {
        def Mesh "Body" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            float3[] extent = [(-1.1, -2.2, -0.1), (1.1, 2.2, 0.1)]
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3]
            point3f[] points = [(-1.1, -2.2, -0.1), (-1.1, -2.2, 0.1), (-1.1, 2.2, -0.1), (-1.1, 2.2, 0.1), (1.1, -2.2, -0.1), (1.1, -2.2, 0.1), (1.1, 2.2, -0.1), (1.1, 2.2, 0.1)]
            rel material:binding = </Device/Materials/DeviceBody>
        }

        def Mesh "Screen" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            float3[] extent = [(-0.95, -1.95, 0.11), (0.95, 1.95, 0.11)]
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-0.95, -1.95, 0.11), (0.95, -1.95, 0.11), (0.95, 1.95, 0.11), (-0.95, 1.95, 0.11)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
                interpolation = "vertex"
            )
            normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "vertex"
            )
            rel material:binding = </Device/Materials/ScreenMaterial>
        }

        def Scope "Materials"
        {
            def Material "DeviceBody"
            {
                token outputs:surface.connect = </Device/Materials/DeviceBody/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0.02, 0.02, 0.02)
                    float inputs:roughness = 0.9
                    token outputs:surface
                }
            }

            def Material "ScreenMaterial"
            {
                token outputs:surface.connect = </Device/Materials/ScreenMaterial/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 0)
                    float inputs:roughness = 1
                    token outputs:surface
                }
            }
        }
    }
    """

    /// The same device with a USD `finish` variant set on its root that
    /// paints the body dark (the default) or red. The body's own colour
    /// goes: a local opinion would outrank every variant.
    static let variantDeviceUSDA = deviceUSDA.replacingOccurrences(
        of: "color3f inputs:diffuseColor = (0.02, 0.02, 0.02)\n", with: ""
    ).replacingOccurrences(
        of: "def Xform \"Device\"\n{\n",
        with: """
        def Xform "Device" (
            variants = {
                string finish = "dark"
            }
            prepend variantSets = "finish"
        )
        {
            variantSet "finish" = {
                "dark" {
                    over "Materials"
                    {
                        over "DeviceBody"
                        {
                            over "Shader"
                            {
                                color3f inputs:diffuseColor = (0.02, 0.02, 0.02)
                            }
                        }
                    }
                }
                "red" {
                    over "Materials"
                    {
                        over "DeviceBody"
                        {
                            over "Shader"
                            {
                                color3f inputs:diffuseColor = (0.8, 0.02, 0.02)
                            }
                        }
                    }
                }
            }

        """
    )

    /// A book: the right half carries the inner screen, and the left leaf
    /// — its cover on the back — turns over it about the hinge (the y axis
    /// at the front face) as `default subtree animation` runs from flat at
    /// 0 s to shut at 5 s, leaving the cover facing the camera.
    static let foldableDeviceUSDA = """
    #usda 1.0
    (
        defaultPrim = "Device"
        upAxis = "Y"
        metersPerUnit = 1
        startTimeCode = 0
        endTimeCode = 5
        timeCodesPerSecond = 1
    )

    def Xform "Device"
    {
        def Mesh "Body" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3]
            point3f[] points = [(0, -2.2, -0.1), (0, -2.2, 0.1), (0, 2.2, -0.1), (0, 2.2, 0.1), (1.1, -2.2, -0.1), (1.1, -2.2, 0.1), (1.1, 2.2, -0.1), (1.1, 2.2, 0.1)]
            rel material:binding = </Device/Materials/DeviceBody>
        }

        def Mesh "Screen" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(0.05, -1.95, 0.11), (1.05, -1.95, 0.11), (1.05, 1.95, 0.11), (0.05, 1.95, 0.11)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
                interpolation = "vertex"
            )
            normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "vertex"
            )
            rel material:binding = </Device/Materials/ScreenMaterial>
        }

        def Xform "Leaf"
        {
            double3 xformOp:translate = (0, 0, 0.12)
            float xformOp:rotateY.timeSamples = {
                0: 0,
                5: 180,
            }
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateY"]

            def Mesh "LeafBody" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
                int[] faceVertexIndices = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3]
                point3f[] points = [(-1.1, -2.2, -0.22), (-1.1, -2.2, -0.02), (-1.1, 2.2, -0.22), (-1.1, 2.2, -0.02), (0, -2.2, -0.22), (0, -2.2, -0.02), (0, 2.2, -0.22), (0, 2.2, -0.02)]
                rel material:binding = </Device/Materials/DeviceBody>
            }

            def Mesh "Cover" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [4]
                int[] faceVertexIndices = [0, 1, 2, 3]
                point3f[] points = [(-0.05, -1.95, -0.23), (-1.05, -1.95, -0.23), (-1.05, 1.95, -0.23), (-0.05, 1.95, -0.23)]
                texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
                    interpolation = "vertex"
                )
                normal3f[] normals = [(0, 0, -1), (0, 0, -1), (0, 0, -1), (0, 0, -1)] (
                    interpolation = "vertex"
                )
                rel material:binding = </Device/Materials/CoverMaterial>
            }
        }

        def Scope "Materials"
        {
            def Material "DeviceBody"
            {
                token outputs:surface.connect = </Device/Materials/DeviceBody/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0.02, 0.02, 0.02)
                    float inputs:roughness = 0.9
                    token outputs:surface
                }
            }

            def Material "ScreenMaterial"
            {
                token outputs:surface.connect = </Device/Materials/ScreenMaterial/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 0)
                    float inputs:roughness = 1
                    token outputs:surface
                }
            }

            def Material "CoverMaterial"
            {
                token outputs:surface.connect = </Device/Materials/CoverMaterial/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 0)
                    float inputs:roughness = 1
                    token outputs:surface
                }
            }
        }
    }
    """
}
