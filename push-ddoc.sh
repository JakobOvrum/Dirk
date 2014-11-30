#!/bin/bash
if [ "$TRAVIS_REPO_SLUG" == "JakobOvrum/Dirk" ] && [ "$TRAVIS_PULL_REQUEST" == "false" ] && [ "$TRAVIS_BRANCH" == "master" ]; then
	echo -e "Generating DDoc...\n"
	git config --global user.email "travis@travis-ci.org"
	git config --global user.name "travis-ci"
	git clone --recursive --quiet --branch=gh-pages https://${GH_TOKEN}@github.com/${TRAVIS_REPO_SLUG} gh-pages > /dev/null
	cd gh-pages
	sh ./generate.sh
	git add -f *.html
	git commit -m "Lastest documentation on successful travis build $TRAVIS_BUILD_NUMBER auto-pushed to gh-pages"
	git push -fq origin gh-pages > /dev/null
	echo -e "Published DDoc to gh-pages.\n"
fi
