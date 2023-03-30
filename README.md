# turnkey

A secret management system for NixOS based on SystemD and Hashicorp Vault

## Summary

This repository will, eventually, hold a flake which provides a configuration
option for NixOS like the following:


```nix
  turnkey = {
    enable = true;
    appRole = "pinky";

    tokens = {
      narf = {
        user = "pinky";
        group = "root";         
        ttl = "15m";
        policies = [
          "narf"  
          "root-token"
        ];

        secrets = {
          zoit = {
            user = "pinky";
            group = "users";
            targetPath = "/home/pinky/zoit.pinky";
            mount = "narf";
            field = "pinky";
          };

          nark = {
            user = "pinky";
            group = "users";
            targetPath = "/home/pinky/nark.brain";
            mount = "narf";
            field = "brain";
          };
        };
      };
    };
  };
```

This configuration will generate a tree of SystemD services which:

1. Create a target, 'turnkey.target', which all other services require
2. Create services which take the approle secret and role ID for the specified
   approle and turn it into a 'root token' which is maintained by the service
   that spawns it
3. Create services that use that root token to create service tokens as
   specified (above, this is just the 'narf' token, but in general may be
   more), and manage it's lifetime and renewal
4. Create services which use the associated service tokens to download and link
   secret information, pulled from Hashicorp Vault, and store it safely on the
   system RAMDisk, and softlink the contents to the specified places.
5. Wire all those services together so that they can be started and stopped en
   masse with a simple 'unlock' script run from an authorized users machine.

## Why use this over sops or agenix or whatever?

You probably shouldn't, but for me, I wanted to maintain a constraint that at
no point should any secret ever live in the Nix Store or in a GH Repo.  I come
from the world of platform engineering for Healthcare systems, in that world,
the relative degree of paranoia is somewhat higher than the broader population.
In practice, this means that we tend to assume if someone can get their hands
on something, even an encrypted something, then that data is fully compromised.
If a secret is maintained in a git repo or in the nix store, then all it takes
to compromise all my secrets is stealing a clone of the git repo, or a copy of
the nix store, both of which fail the 'abusive ex' metric that I've come to use
as the main yardstick for security.

To address that, turnkey offers a couple of features:

1. Nothing is ever stored outside of Vault or the host's RAM disk at
   `/run/keys`.
2. Tokens can have aggressive `ttl`s assigned, because `systemd` can manage
   renewing them as needed.
3. Locking a system is as easy as de-isolating from the turnkey target,
   services will shut down, triggering their cleanup phase, which removes all
   associated secrets.
4. Rebooting a system returns it to a _locked_ state, so systems fail safe.

This fits my goals nicely, and lets me manage secrets quite easily. 

## What state is this all in?

It works on a single test machine, I have not begun using it in anger in my
lab. However, the version present in this repo can pull secrets and link them
to the correct locations.

Still todo:

1. Big refactor, this is a total mess. The nix language does not make it
   obvious how to share code across files, tap the "Nix Docs Bad" sign.
2. Using this across my lab so I can chase out bugs.
3. Refresh logic. Tokens will eventually time out after the maximum TTL is
   reached, also the tokens do live on system. It would be good to make it
   automatically replace tokens on some configurable schedule.

In it's current state, it correctly wires up services to each other so it
cleans up when the turnkey target is killed, or when one of the token services
fails. It can retrieve multiple fields from a single secret.


