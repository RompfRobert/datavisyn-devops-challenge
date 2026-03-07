# Helm Charts

This folder contains two minimal but working Helm charts:

- `frontend`: Deploys the 2048 web app (`public.ecr.aws/l6m2t8p7/docker-2048`)
- `backend`: Deploys a dummy HTTP echo backend (`hashicorp/http-echo`)

## Install

```bash
helm upgrade --install backend ./helm/backend -n demo --create-namespace
helm upgrade --install frontend ./helm/frontend -n demo
```

## Verify

```bash
kubectl get pods,svc -n demo
```

## Quick local access with port-forward

```bash
kubectl port-forward svc/frontend 8080:80 -n demo
kubectl port-forward svc/backend 8081:80 -n demo
```

- Frontend: http://localhost:8080
- Backend: http://localhost:8081
