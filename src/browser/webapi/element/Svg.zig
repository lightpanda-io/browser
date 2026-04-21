// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
pub const Generic = @import("svg/Generic.zig");
pub const Unknown = @import("svg/Unknown.zig");
pub const GraphicsElement = @import("svg/GraphicsElement.zig");
pub const GeometryElement = @import("svg/GeometryElement.zig");
pub const Rect = @import("svg/Rect.zig");
pub const Circle = @import("svg/Circle.zig");
pub const Ellipse = @import("svg/Ellipse.zig");
pub const Line = @import("svg/Line.zig");
pub const Polyline = @import("svg/Polyline.zig");
pub const Polygon = @import("svg/Polygon.zig");
pub const Path = @import("svg/Path.zig");
pub const SvgSvg = @import("svg/SvgSvg.zig");
pub const G = @import("svg/G.zig");
pub const Defs = @import("svg/Defs.zig");
pub const Symbol = @import("svg/Symbol.zig");
pub const Use = @import("svg/Use.zig");
pub const Switch = @import("svg/Switch.zig");
pub const ForeignObject = @import("svg/ForeignObject.zig");
pub const Image = @import("svg/Image.zig");
pub const Desc = @import("svg/Desc.zig");
pub const Title = @import("svg/Title.zig");
pub const Metadata = @import("svg/Metadata.zig");
pub const TextContent = @import("svg/TextContent.zig");
pub const TextPositioning = @import("svg/TextPositioning.zig");
pub const Text = @import("svg/Text.zig");
pub const TSpan = @import("svg/TSpan.zig");
pub const TextPath = @import("svg/TextPath.zig");
pub const A = @import("svg/A.zig");
pub const View = @import("svg/View.zig");
pub const SvgScript = @import("svg/SvgScript.zig");
pub const SvgStyle = @import("svg/SvgStyle.zig");
pub const GradientElement = @import("svg/GradientElement.zig");
pub const LinearGradient = @import("svg/LinearGradient.zig");
pub const RadialGradient = @import("svg/RadialGradient.zig");
pub const Stop = @import("svg/Stop.zig");
pub const Pattern = @import("svg/Pattern.zig");
pub const ClipPath = @import("svg/ClipPath.zig");
pub const Mask = @import("svg/Mask.zig");
pub const Marker = @import("svg/Marker.zig");
pub const Filter = @import("svg/Filter.zig");
pub const FEBlend = @import("svg/fe/Blend.zig");
pub const FEColorMatrix = @import("svg/fe/ColorMatrix.zig");
pub const FEComponentTransfer = @import("svg/fe/ComponentTransfer.zig");
pub const FEComposite = @import("svg/fe/Composite.zig");
pub const FEConvolveMatrix = @import("svg/fe/ConvolveMatrix.zig");
pub const FEDiffuseLighting = @import("svg/fe/DiffuseLighting.zig");
pub const FEDisplacementMap = @import("svg/fe/DisplacementMap.zig");
pub const FEDistantLight = @import("svg/fe/DistantLight.zig");
pub const FEDropShadow = @import("svg/fe/DropShadow.zig");
pub const FEFlood = @import("svg/fe/Flood.zig");
pub const FEFuncR = @import("svg/fe/FuncR.zig");
pub const FEFuncG = @import("svg/fe/FuncG.zig");
pub const FEFuncB = @import("svg/fe/FuncB.zig");
pub const FEFuncA = @import("svg/fe/FuncA.zig");
pub const FEGaussianBlur = @import("svg/fe/GaussianBlur.zig");
pub const FEImage = @import("svg/fe/Image.zig");
pub const FEMerge = @import("svg/fe/Merge.zig");
pub const FEMergeNode = @import("svg/fe/MergeNode.zig");
pub const FEMorphology = @import("svg/fe/Morphology.zig");
pub const FEOffset = @import("svg/fe/Offset.zig");
pub const FEPointLight = @import("svg/fe/PointLight.zig");
pub const FESpecularLighting = @import("svg/fe/SpecularLighting.zig");
pub const FESpotLight = @import("svg/fe/SpotLight.zig");
pub const FETile = @import("svg/fe/Tile.zig");
pub const FETurbulence = @import("svg/fe/Turbulence.zig");
pub const AnimationElement = @import("svg/AnimationElement.zig");
pub const Animate = @import("svg/Animate.zig");
pub const AnimateSet = @import("svg/AnimateSet.zig");
pub const AnimateMotion = @import("svg/AnimateMotion.zig");
pub const AnimateTransform = @import("svg/AnimateTransform.zig");
pub const MPath = @import("svg/MPath.zig");

const String = lp.String;

const Svg = @This();
_type: Type,
_proto: *Element,
_tag_name: String, // Svg elements are case-preserving

pub const Type = union(enum) {
    svg: *SvgSvg,
    generic: *Generic,
    unknown: *Unknown,
    rect: *Rect,
    circle: *Circle,
    ellipse: *Ellipse,
    line: *Line,
    polyline: *Polyline,
    polygon: *Polygon,
    path: *Path,
    g: *G,
    defs: *Defs,
    symbol: *Symbol,
    use: *Use,
    @"switch": *Switch,
    foreign_object: *ForeignObject,
    image: *Image,
    desc: *Desc,
    title: *Title,
    metadata: *Metadata,
    text: *Text,
    tspan: *TSpan,
    text_path: *TextPath,
    a: *A,
    view: *View,
    svg_script: *SvgScript,
    svg_style: *SvgStyle,
    linear_gradient: *LinearGradient,
    radial_gradient: *RadialGradient,
    stop: *Stop,
    pattern: *Pattern,
    clip_path: *ClipPath,
    mask: *Mask,
    marker: *Marker,
    filter: *Filter,
    fe_blend: *FEBlend,
    fe_color_matrix: *FEColorMatrix,
    fe_component_transfer: *FEComponentTransfer,
    fe_composite: *FEComposite,
    fe_convolve_matrix: *FEConvolveMatrix,
    fe_diffuse_lighting: *FEDiffuseLighting,
    fe_displacement_map: *FEDisplacementMap,
    fe_distant_light: *FEDistantLight,
    fe_drop_shadow: *FEDropShadow,
    fe_flood: *FEFlood,
    fe_func_r: *FEFuncR,
    fe_func_g: *FEFuncG,
    fe_func_b: *FEFuncB,
    fe_func_a: *FEFuncA,
    fe_gaussian_blur: *FEGaussianBlur,
    fe_image: *FEImage,
    fe_merge: *FEMerge,
    fe_merge_node: *FEMergeNode,
    fe_morphology: *FEMorphology,
    fe_offset: *FEOffset,
    fe_point_light: *FEPointLight,
    fe_specular_lighting: *FESpecularLighting,
    fe_spot_light: *FESpotLight,
    fe_tile: *FETile,
    fe_turbulence: *FETurbulence,
    animate: *Animate,
    animate_set: *AnimateSet,
    animate_motion: *AnimateMotion,
    animate_transform: *AnimateTransform,
    mpath: *MPath,
};

pub fn is(self: *Svg, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == T) {
                return &@field(self._type, f.name);
            }
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn asElement(self: *Svg) *Element {
    return self._proto;
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: Svg" {
    try testing.htmlRunner("element/svg", .{});
}
