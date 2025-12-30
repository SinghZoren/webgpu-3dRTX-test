@group(0) @binding(0) var srcTex : texture_storage_2d<rgba16float, read>;
@group(0) @binding(1) var dstTex : texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let pix = vec2<i32>(i32(gid.x), i32(gid.y));
  let col = textureLoad(srcTex, pix);
  textureStore(dstTex, pix, col);
}







