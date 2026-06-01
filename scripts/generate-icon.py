import numpy as np
from PIL import Image
import os, math

SRC = "/tmp/tetonne1.png"
OUT = "/tmp/iconout"
os.makedirs(OUT, exist_ok=True)

im = Image.open(SRC).convert("RGB")
a = np.asarray(im).astype(int)
r,g,b = a[...,0],a[...,1],a[...,2]
mx=np.maximum(np.maximum(r,g),b); mn=np.minimum(np.minimum(r,g),b)
sat=mx-mn; bright=mx
core = (sat>28) | ((bright<140)&(b>=r))
ys,xs=np.where(core)
x0,x1,y0,y1 = xs.min(),xs.max(),ys.min(),ys.max()
cx,cy = (x0+x1)/2.0,(y0+y1)/2.0
side = max(x1-x0, y1-y0)
half = side/2.0 + 6   # tiny margin
L=int(round(cx-half)); T=int(round(cy-half)); S=int(round(2*half))
crop = im.crop((L,T,L+S,T+S)).resize((1024,1024), Image.LANCZOS)

# macOS continuous-corner squircle (superellipse) mask, full-bleed
N=1024
yy,xx=np.mgrid[0:N,0:N].astype(float)
xn=(xx-(N-1)/2)/((N-1)/2); yn=(yy-(N-1)/2)/((N-1)/2)
n=5.0
d=np.abs(xn)**n+np.abs(yn)**n
# antialiased edge around d==1
edge=0.06
alpha=np.clip((1.0-d)/edge + 0.5, 0, 1)
alpha=(alpha*255).astype(np.uint8)

rgba=np.dstack([np.asarray(crop), alpha])
master=Image.fromarray(rgba,"RGBA")
master.save(f"{OUT}/master_1024.png")
print("crop box", (L,T,S), "-> 1024 squircle saved")

# iconset
iconset=f"{OUT}/AppIcon.iconset"; os.makedirs(iconset, exist_ok=True)
sizes=[(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
       (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
       (512,"512x512"),(1024,"512x512@2x")]
for px,name in sizes:
    master.resize((px,px),Image.LANCZOS).save(f"{iconset}/icon_{name}.png")
print("iconset written")
