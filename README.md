# march - a go deployment tool written in ruby

March is an in-house deployment tool that acts as an insanely lightweight capistrano and allows you to build and deploy
a go package to run as a pseudo-daemon on remote servers without any hassle.

## setup

Create a `march` directory containing a single file: `config.yml`.

In this file, you can specify the following options:

    # Specifies the remote path to which march will deploy.
    deploy_path: /home/deploy/yourscript
    
    # Specify extra env vars. 
    env:
      ENV_FILENAME: /home/deploy/yourscript/.env
    
    # The name of the binary generated by `go build`. 
    go_binary_name: yourscript
       
    server_defaults:
      go_os: linux
      user: deploy
      port: 22
    
    stages:
      staging:
        servers:
          - host: staging.yourapp.com
    
      production:
        servers:
          - host: app-1.yourapp.com
            port: 2222
          - host: app-2.yourapp.com
          - host: app-3.yourapp.com

All files in the assets/ folder in your Go source directly will be copied directly to the server and can be accessed at
`os.Getenv('MARCH_ASSETS_PATH')`.

## commands

**format**: `march {stage} {command}`

- `deploy`: builds your go package into a binary and uploads it along with some support files to your `deploy_path` on 
  all servers matching that stage.
- `logs`: experimental, does not respond to SIGKILL, but tails the logs of your go program