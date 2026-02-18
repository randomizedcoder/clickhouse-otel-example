# clickhouse-otel-example
clickhouse-otel-example


This is a demo of an open telemetry logs pipeline.  The general idea is that the json logs, will have some standard fields that we can aggregate by, so the hyperdx will be able to show the number of logs that container the number 10, and one of the random words, as a query example.  This is to demontrate what a typical operational debug logging pipeline might want to do.

The key components are:

1. go program runs a simple sleep loop printing a random number [0-100], and a random string (from a set of 10 strings), every 5 seconds using the zap logging library (so the log is json)
2. go program running in minikube (mini kubernetes cluster)
3. fluentbit daemonset running, reading the logs from the go program
4. fluentbit uses lua to convert the json logs into open telemetry (otel) format
5. fluentbit will post the messages into a clickhouse table
6. hypderdx container used to query clickhouse to show the logs

Go
The go code needs to be idiomatic, use the https://github.com/uber-go/zap logging library.
Need a single main.go, that will catch signals and shutdown cleanly.
There will be a primary loop, that will count, and print the random number [0-100], and a random string (from a set of 10 strings), every 5 seconds using the zap logging library.
The go code will have cli flags for the:
- range of the random numbers
- how many random strings
- sleep duration for the loop
The cli flags need to be able to be overwritten by environment variables, because this is the common way to pass arguemnts with containers.
The main.go will import the loop.go code, such that the functions to return the random numbers and strings can easily have unit tests, and we will have unit tests.

This repo uses nix.  The nix means we can use the nixpkgs, which includes many of the features we need.
1. nix will be used to compile and run the go program.  we need to be able to run the go, and run the tests, race tests.
2. nix will create an OCI container to put the go code into.  This needs to NOT rely on the /nix/store, so no bind mounts, but to contain everything required to run the OCI container on its own. e.g. Copy the OCI image to another machine, like a debian, and be able to start the continer in docker.
3. nix will create a fluentbit ( https://github.com/randomizedcoder/fluent-bit ) OCI container.  Needs to NOT reply on /nix/store. We need to be able to configure a lua script that the fluentbit will run inside the container.  There is NOT a nixpkgs for fluentbit, so we will need nix to download from github, do the NAR hash, and so on.  The fluent-bit repo is available locally at ~/Downloads/fluent-bit/
4. nix will create a clickhouse container.  Needs to be stand alone also.  There is a nixpkg for clickhouse: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/cl/clickhouse/generic.nix.  The nixpkgs repo is available locally, in ~/Downloads/nixpkgs/ so you can review it.
5. nix will create a hyperdx container (https://github.com/randomizedcoder/hyperdx ).  stand alone.  the source is available locally at: /home/das/Downloads/hyperdx
7. nix is used to create a microvm virtual machine. inside the virtual machine runs minikube, and there is a nixpkg for minikube. https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/mi/minikube/package.nix.  remember the nixpkgs is available locally.  The microvm repo is cloned locally for review at ~/Downloads/microvm.nix/
8. nix virtual machine will need to have the go OCI, fluentbit OCI, clickhouse OCI, hyperDX OCI container images all available within the microvm.
9. nix virtual machine will need a script to load the container images into the minikube container cache

Kubernetes config
For the minikube, we will need kubernetes configs to:
1. start fluentbit as daemonset.  fluentbit to consume the logs from the go container.
2. start go container.  will need to set environment variables to set 0-100 integars. 10 strings. 5 second duration
3. start the clickhouse database. open tcp port to allow connecing to all the clickhouse ports
4. start the hyperdx. open the tcp port


   
