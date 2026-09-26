# Compose sticker SVGs from Fluent Emoji (MIT) parts: pick drawing elements by index, optional clip to y < clipY.
import copy, os, sys
import xml.etree.ElementTree as ET
ET.register_namespace('', 'http://www.w3.org/2000/svg')
NS='{http://www.w3.org/2000/svg}'
def parts(name):
    root=ET.parse(f'svg_{name}.svg').getroot()
    kids=list(root); defs=[k for k in kids if k.tag==NS+'defs']
    draw=[k for k in kids if k.tag!=NS+'defs']
    wrap=None
    if len(draw)==1 and draw[0].tag==NS+'g':
        wrap=draw[0]; draw=list(wrap)
    return root, defs, draw, wrap
def compose(out, name, idx=None, clipY=None):
    root, defs, draw, wrap = parts(name)
    r=ET.Element(root.tag, root.attrib)
    for d in defs: r.append(copy.deepcopy(d))
    container=r
    if clipY is not None:
        d=ET.SubElement(r, NS+'defs')
        cp=ET.SubElement(d, NS+'clipPath', {'id':'stickerclip'})
        ET.SubElement(cp, NS+'rect', {'x':'0','y':'0','width':'32','height':str(clipY)})
        container=ET.SubElement(r, NS+'g', {'clip-path':'url(#stickerclip)'})
    if wrap is not None:
        container=ET.SubElement(container, NS+'g', dict(wrap.attrib))
    sel = draw if idx is None else [draw[i] for i in idx]
    for el in sel: container.append(copy.deepcopy(el))
    os.makedirs('out_svg', exist_ok=True)
    ET.ElementTree(r).write(f'out_svg/{out}.svg')
R=range
jobs = {
 'ears_dog':   ('dog_face', [11]+list(R(23,32)), None),
 'nose_dog':   ('dog_face', [39,40,41,42], None),
 'tongue_dog': ('dog_face', [15,16], None),
 'ears_cat':   ('cat_face', [0,7,8,38,40,42], float(sys.argv[1]) if len(sys.argv)>1 else 7.0),
 'whiskers_cat': ('cat_face', [11,12]+list(R(14,28)), None),
 'ears_rabbit': ('rabbit_face', [0]+list(R(11,24)), float(sys.argv[2]) if len(sys.argv)>2 else 9.0),
 'nose_rabbit': ('rabbit_face', [24,25,26,27,33,34,35], None),
 'ears_bear':  ('bear', list(R(0,10)), None),
 'nose_bear':  ('bear', list(R(23,28))+list(R(32,38)), None),
 'ears_mouse': ('mouse_face', list(R(0,5)), None),
 'whiskers_mouse': ('mouse_face', list(R(17,35)), None),
 'halo':       ('smiling_face_with_halo', [0,1,18,19], None),
 'horns':      ('smiling_face_with_horns', [11,12,13], None),
}
for whole in ['crown','cherry_blossom','blossom','hibiscus','red_heart','sparkling_heart','sunglasses','glasses','ribbon','top_hat','graduation_cap','butterfly','sparkles','star','glowing_star','two_hearts','four_leaf_clover','maple_leaf','snowflake','musical_notes','bubbles','kiss_mark','rainbow','dizzy','gem_stone','tulip','rose','sunflower']:
    jobs[whole]=(whole, None, None)
for out,(name,idx,clip) in jobs.items(): compose(out,name,idx,clip)
print(len(jobs))
