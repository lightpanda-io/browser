#!/usr/bin/env bash
#
# Build the two HN story videos. Each is: a 1s frozen lead-in frame, a step1
# still, sped-up/normal clips, a step2 still, then closing clips. Everything is
# normalized to 1514x1032 @ 60fps CFR so the pieces concatenate seamlessly.
#
# The frozen lead-in is extracted to a PNG first (input-seek lands on the frame
# displayed at that timestamp) because these are sparse VFR screen recordings:
# a sub-second trim window inside the filtergraph can contain zero frames.
#
set -euo pipefail

norm="scale=1514:1032,setsar=1,fps=60,format=yuv420p"

# ============================================================================
# Story 1 — from hn-scrape.mp4
# ============================================================================
ffmpeg -y -ss 16.5 -i hn-scrape.mp4 -frames:v 1 frame-scrape-16.5.png

ffmpeg -y \
  -i hn-scrape.mp4 \
  -loop 1 -t 3 -i step1.png \
  -loop 1 -t 3 -i step2.png \
  -loop 1 -t 1 -i frame-scrape-16.5.png \
  -filter_complex "\
[3:v]${norm}[frz];\
[1:v]${norm}[img1];\
[2:v]${norm}[img2];\
[0:v]trim=16.5:20,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[a];\
[0:v]trim=20:72,setpts=(PTS-STARTPTS)/5,fps=60,scale=1514:1032,setsar=1,format=yuv420p[b];\
[0:v]trim=72:73,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[c];\
[0:v]trim=94:105,setpts=(PTS-STARTPTS)/5,fps=60,scale=1514:1032,setsar=1,format=yuv420p[d];\
[0:v]trim=105:112,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[e];\
[0:v]trim=119.5:126.5,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[f];\
[0:v]trim=start=134.5,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[g];\
[frz][img1][a][b][c][d][e][img2][f][g]concat=n=10:v=1[out]" \
  -map "[out]" -fps_mode cfr -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p hn-story-scrape.mp4

# ============================================================================
# Story 2 — from hn-karma.mp4
# ============================================================================
ffmpeg -y -ss 18 -i hn-karma.mp4 -frames:v 1 frame-karma-18.png

ffmpeg -y \
  -i hn-karma.mp4 \
  -loop 1 -t 3 -i step1.png \
  -loop 1 -t 3 -i step2.png \
  -loop 1 -t 1 -i frame-karma-18.png \
  -filter_complex "\
[3:v]${norm}[frz];\
[1:v]${norm}[img1];\
[2:v]${norm}[img2];\
[0:v]trim=18:27,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[a];\
[0:v]trim=27:57,setpts=(PTS-STARTPTS)/5,fps=60,scale=1514:1032,setsar=1,format=yuv420p[b];\
[0:v]trim=67:75,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[c];\
[0:v]trim=75:81,setpts=(PTS-STARTPTS)/5,fps=60,scale=1514:1032,setsar=1,format=yuv420p[d];\
[0:v]trim=100:105,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[e];\
[0:v]trim=105:114,setpts=(PTS-STARTPTS)/5,fps=60,scale=1514:1032,setsar=1,format=yuv420p[f];\
[0:v]trim=114:117,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[g];\
[0:v]trim=126:132,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[h];\
[0:v]trim=138:146,setpts=PTS-STARTPTS,fps=60,scale=1514:1032,setsar=1,format=yuv420p[i];\
[frz][img1][a][b][c][d][e][f][g][img2][h][i]concat=n=12:v=1[out]" \
  -map "[out]" -fps_mode cfr -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p hn-story-karma.mp4

echo "done:"
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 hn-story-scrape.mp4
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 hn-story-karma.mp4
