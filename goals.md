# Datavisyn DevOps Challenge

## Goals

The goal of this challenge is to get an impression whether you are able to handle the basics of
the datavisyn technology stack. The challenge requires you to set up a very basic Kubernetes
deployment with a few pods, authentication, and more.  

## Challenge

For this challenge, we want you to deploy an arbitrary image of a web application on a
Kubernetes cluster of your choice (minikube or AWS EKS). In the end, the web application
should be accessible locally on <localhost/ip of cluster>:<port>. You can choose the image you
want to use, but you should create the Helm chart yourself. As a reference, our products usually
consist of two or more images, like a FastAPI backend image, an NGINX frontend image, ...

### Setting up a cluster using Terraform  

Ideally, you will be using Terraform to provision the resources in an infrastructure-as-code way.
In the end, Terraform configuration files (*.tf) should include all required resources to provision a
new cluster. If you are using minikube, you are still required to provide the Terraform files as if
you were using AWS.

### Creating and installing your Helm Chart(s)

Now that you have a cluster up and running, you can install your Helm chart(s). Feel free to use
an image of your choice for the Helm chart(s).

### Adding secrets

In the next step, you will need to configure your authentication. For that to work, you will need to
provide secret values to your pods/ingresses. For instance, we are using helm-secrets to store
secrets securely in Git environments. In this step, you should find a way of adding and
consuming secrets in a secure way using a method of your choice.  

### Adding authentication

For authentication, we usually use OAuth2/OIDC. It is generally very easy to integrate this into
applications, as most ingresses already have support for authentication values in combination
with oauth2-proxy. You can choose any SSO provider of your choice for testing purposes, with a
local keycloak or Github being easy choices.

You are free to choose any way of providing OAuth2/OIDC authentication. If you are using AWS
EKS, you can use the ALB OIDC functionality, or an ingress with authentication functionality
included (like Kong). In case of using the standard Ingress-NGINX controller, one can easily add
authentication by using two ingresses, one for the downstream web application, and one for the
authentication. 

See this [guide](https://kubernetes.github.io/ingress-nginx/examples/auth/oauth-external-auth/) for more information.

Generally, the flow for the Ingress-NGINX controller looks like this:

1. A request is made to /
2. The first ingress will check if the user is authenticated, if not redirect to /oauth2
3. A request is made to /oauth2/..., causing the second ingress to forward it to the
oauth2-proxy
4. The OAuth2 flow will start with the registered SSO provider
5. After a successful login, the oauth2-proxy will set a cookie and redirect back to /
6. The first ingress will check again if the user is logged in (by asking the oauth2-proxy),
and forward the request to the frontend image

![alt text](image.png)

### Bonus tasks: Setup and configure ArgoCD

1. Set up and configure ArgoCD for managing your application. ArgoCD should be synced
with your Github repository.
2. Set up authentication for the ArgoCD instance (similar to the authentication for your
application)

### Final steps

Document your steps in such detail that allows reproducing the results for an experienced
DevOps engineer. A concise, half-page README will be sufficient, we do not require you to
write a complete technical documentation. Ideally, you commit all your infrastructure to a Github
repository of your choice. Finally, share the repository with us. Details will be provided in the
initial conversation.

### Important remarks

This challenge is meant to evaluate your current standing and reflects one of many day to day
tasks as DevOps engineer. You are not expected to know everything about our stack, so feel
free to find novel solutions and impress us with your creativity. We are always looking for
someone with new ideas and technical skills. So in case you want to deploy a different pod, use
a different way of authentication, or build a telemetry stack instead, feel free to do so. This is
merely a guideline of what we are looking for.
