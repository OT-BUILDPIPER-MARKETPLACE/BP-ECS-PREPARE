# BP-SHELL-STEP-TEMPLATE
I'll <do xyz>

## Setup
* Clone the code available at [BP-SHELL-STEP-TEMPLATE](https://github.com/OT-BUILDPIPER-MARKETPLACE/BP-SHELL-STEP-TEMPLATE)

* Build the docker image
```
git submodule init
git submodule update
docker build -t ot/<image-name>:0.1 .
```

* Do local testing
```
docker run -it --rm -v $PWD:/src -e var1="key1" -e var2="key2" ot/<image-name>:0.1
```

* Debug
```
docker run -it --rm -v $PWD:/src -e var1="key1" -e var2="key2" --entrypoint sh ot/<image-name>:0.1
```