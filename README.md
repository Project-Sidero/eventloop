# Event loop & threads

## Executing examples

On Posix you will need to install the -dev package for OpenSSL.

To get the loading of sidero shared libraries you will need to set the LD path before execution.

E.g. ``export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:~/projects/ProjectSidero/eventloop/examples/networking``

or you can patch the binary:

``patchelf --force-rpath --set-rpath ~/projects/ProjectSidero/eventloop/examples/networking ./example_networking``
