FROM nginx:alpine
# Replace the default server with ours (port 8080, OTA content types).
COPY default.conf /etc/nginx/conf.d/default.conf
# The release artifacts (Gecko.ipa, manifest.plist, index.html) produced by
# deploy-friend.sh, copied into ./dist in this build context before building.
COPY dist/ /usr/share/nginx/html/
EXPOSE 8080
