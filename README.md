# turnkey

A secret management system for NixOS based on SystemD and Hashicorp Vault

## Summary

This repository will, eventually, hold a flake which provides a configuration option for NixOS like the following:


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
2. Create services which take the approle secret and role ID for the specified approle and turn it into a 'root token' which is maintained by 
   the service that spawns it
3. Create services that use that root token to create service tokens as specified (above, this is just the 'narf' token, but in general may be 
   more), and manage it's lifetime and renewal
4. Create services which use the associated service tokens to download and link secret information, pulled from Hashicorp Vault, and store it 
   safely on the system RAMDisk, and softlink the contents to the specified places.
5. Wire all those services together so that they can be started and stopped en masse with a simple 'unlock' script run from an authorized users
   machine.

## Why use this over sops or agenix or whatever?

You probably shouldn't, but for me, I wanted to maintain a constraint that at no point should any secret ever live in the Nix Store or in a GH Repo.
I come from the world of platform engineering for Healthcare systems, in that world, the relative degree of paranoia is somewhat higher than the 
broader population. In practice, this means that we tend to assume if someone can get their hands on something, even an encrypted something, then
that data is fully compromised. If a secret is maintained in a git repo or in the nix store, then all it takes to compromise all my secrets is stealing
a clone of the git repo, or a copy of the nix store, both of which fail the 'abusive ex' metric that I've come to use as the main yardstick for security.

To address that, turnkey offers a couple of features:

1. Nothing is ever stored outside of Vault or the host's RAM disk at `/run/keys`.
2. Tokens can have aggressive `ttl`s assigned, because `systemd` can manage renewing them as needed.
3. Locking a system is as easy as de-isolating from the turnkey target, services will shut down, triggering their cleanup phase, which removes all
   associated secrets.
4. Rebooting a system returns it to a _locked_ state, so systems fail safe.

This fits my goals nicely, and lets me manage secrets quite easily. 

## Why isn't anything here yet?

Well because I haven't extracted it from the larger IaC that drives my lab, and because it's not like, 100% done? There's an early version of it if 
you're morbidly curious [here](https://gist.github.com/jfredett/344994e959b7a530e2701dadc765f15d). Again, I can't recommend enough that you don't 
use this, go outside instead, it's better for you than computers.

