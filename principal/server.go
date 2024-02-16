package principal

import (
	"bytes"
	context "context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net/http"
	"sync"
	"time"

	appclientset "github.com/argoproj/argo-cd/v2/pkg/client/clientset/versioned"
	"github.com/jannfis/argocd-agent/internal/auth"
	"github.com/jannfis/argocd-agent/internal/backend/kubernetes"
	"github.com/jannfis/argocd-agent/internal/event"
	appinformer "github.com/jannfis/argocd-agent/internal/informers/application"
	"github.com/jannfis/argocd-agent/internal/issuer"
	"github.com/jannfis/argocd-agent/internal/manager/application"
	"github.com/jannfis/argocd-agent/internal/metrics"
	"github.com/jannfis/argocd-agent/internal/queue"
	"github.com/jannfis/argocd-agent/internal/version"
	"github.com/jannfis/argocd-agent/pkg/types"
	"github.com/sirupsen/logrus"
	"google.golang.org/grpc"
)

type Server struct {
	options      *ServerOptions
	tlsConfig    *tls.Config
	listener     *Listener
	server       *http.Server
	grpcServer   *grpc.Server
	authMethods  *auth.Methods
	queues       *queue.SendRecvQueues
	namespace    string
	issuer       issuer.Issuer
	noauth       map[string]bool // noauth contains endpoints accessible without authentication
	ctx          context.Context
	ctxCancel    context.CancelFunc
	appManager   *application.ApplicationManager
	informer     *appinformer.AppInformer
	watchLock    sync.RWMutex
	clientMap    map[string]string
	namespaceMap map[string]types.AgentMode
	clientLock   sync.RWMutex
	events       *event.Event
}

// noAuthEndpoints is a list of endpoints that are available without the need
// for the request to be authenticated.
var noAuthEndpoints = map[string]bool{
	"/versionapi.Version/Version":          true,
	"/authapi.Authentication/Authenticate": true,
}

const waitForSyncedDuration = 1 * time.Second

func NewServer(ctx context.Context, appClient appclientset.Interface, namespace string, opts ...ServerOption) (*Server, error) {
	s := &Server{
		options:   defaultOptions(),
		queues:    queue.NewSendRecvQueues(),
		namespace: namespace,
		noauth:    noAuthEndpoints,
	}

	s.ctx, s.ctxCancel = context.WithCancel(ctx)

	for _, o := range opts {
		err := o(s)
		if err != nil {
			return nil, err
		}
	}

	if s.authMethods == nil {
		s.authMethods = auth.NewMethods()
	}

	var err error

	// The server supports generating and using a volatile signing keys for the
	// tokens it issues. This should not be used in production.
	if s.options.signingKey == nil {
		log().Warnf("Generating and using a volatile token signing key - multiple replicas not possible")
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return nil, fmt.Errorf("could not generate signing key: %v", err)
		}
		s.options.signingKey = key
	}

	s.issuer, err = issuer.NewIssuer("argocd-agent-server", issuer.WithRSAPrivateKey(s.options.signingKey))
	if err != nil {
		return nil, err
	}

	informerOpts := []appinformer.AppInformerOption{
		appinformer.WithNamespaces(s.options.namespaces...),
		appinformer.WithNewAppCallback(s.newAppCallback),
		appinformer.WithUpdateAppCallback(s.updateAppCallback),
		appinformer.WithDeleteAppCallback(s.deleteAppCallback),
	}

	managerOpts := []application.ApplicationManagerOption{
		application.WithAllowUpsert(true),
	}

	if s.options.metricsPort > 0 {
		informerOpts = append(informerOpts, appinformer.WithMetrics(metrics.NewApplicationWatcherMetrics()))
		managerOpts = append(managerOpts, application.WithMetrics(metrics.NewApplicationClientMetrics()))
	}

	s.informer = appinformer.NewAppInformer(s.ctx, appClient,
		s.namespace,
		informerOpts...,
	)

	s.appManager = application.NewApplicationManager(kubernetes.NewKubernetesBackend(appClient, s.informer, true), s.namespace,
		managerOpts...,
	)

	s.clientMap = map[string]string{
		`{"clientID":"argocd","mode":"autonomous"}`: "argocd",
	}
	s.namespaceMap = map[string]types.AgentMode{
		"argocd": types.AgentModeAutonomous,
	}

	return s, nil
}

// Start starts the Server s and its listeners in their own go routines. Any
// error during startup, before the go routines are running, will be returned
// immediately. Errors during the runtime will be propagated via errch.
func (s *Server) Start(ctx context.Context, errch chan error) error {
	log().Infof("Starting %s (server) v%s (ns=%s, allowed_namespaces=%v)", version.Name(), version.Version(), s.namespace, s.options.namespaces)
	if s.options.serveGRPC {
		if err := s.serveGRPC(s.ctx, errch); err != nil {
			return err
		}
	}

	if s.options.metricsPort > 0 {
		metrics.StartMetricsServer(metrics.WithListener("", s.options.metricsPort))
	}

	err := s.StartEventProcessor(s.ctx)
	if err != nil {
		return nil
	}

	// The application informer lives in its own go routine
	go func() {
		s.appManager.Application.StartInformer(ctx)
	}()

	s.events = event.NewEventEmitter(s.options.serverName)

	s.informer.EnsureSynced(waitForSyncedDuration)
	log().Infof("Informer synced and ready")

	return nil
}

// Shutdown shuts down the server s. If no server is running, or shutting down
// results in an error, an error is returned.
func (s *Server) Shutdown() error {
	var err error

	log().Debugf("Shutdown requested")
	// Cancel server-wide context
	s.ctxCancel()

	if s.server != nil {
		if s.options.gracePeriod > 0 {
			ctx, cancel := context.WithTimeout(context.Background(), s.options.gracePeriod)
			defer cancel()
			log().Infof("Server shutdown requested, allowing client connections to shut down for %v", s.options.gracePeriod)
			err = s.server.Shutdown(ctx)
		} else {
			log().Infof("Closing server")
			err = s.server.Close()
		}
		s.server = nil
	} else if s.grpcServer != nil {
		log().Infof("Shutting down server")
		s.grpcServer.Stop()
		s.grpcServer = nil
	} else {
		return fmt.Errorf("no server running")
	}
	return err
}

func (s *Server) loadTLSConfig() (*tls.Config, error) {
	var cert tls.Certificate
	var err error
	if s.options.tlsCertPath != "" && s.options.tlsKeyPath != "" {
		cert, err = tls.LoadX509KeyPair(s.options.tlsCertPath, s.options.tlsKeyPath)
		if err != nil {
			return nil, fmt.Errorf("could not load X509 keypair: %w", err)
		}
		for _, c := range cert.Certificate {
			cert, err := x509.ParseCertificate(c)
			if err != nil {
				return nil, fmt.Errorf("could not parse certificate from %s: %w", s.options.tlsCertPath, err)
			}
			if !cert.NotAfter.After(time.Now()) {
				log().Warnf("Server certificate has expired on %s", cert.NotAfter.Format(time.RFC1123Z))
			}
		}
	} else if s.options.tlsCert != nil && s.options.tlsKey != nil {
		cBytes := &bytes.Buffer{}
		kBytes := &bytes.Buffer{}
		err := pem.Encode(cBytes, &pem.Block{Type: "CERTIFICATE", Bytes: s.options.tlsCert.Raw})
		if err != nil {
			return nil, fmt.Errorf("error encoding cert: %w", err)
		}
		err = pem.Encode(kBytes, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(s.options.tlsKey)})
		if err != nil {
			return nil, fmt.Errorf("error encoding key: %w", err)
		}
		cert, err = tls.X509KeyPair(cBytes.Bytes(), kBytes.Bytes())
		if err != nil {
			return nil, fmt.Errorf("error creating key pair: %w", err)
		}
	} else {
		return nil, fmt.Errorf("TLS not configured")
	}
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
	}
	return tlsConfig, nil
}

// Listener returns the listener of Server s
func (s *Server) Listener() *Listener {
	return s.listener
}

// TokenIssuer returns the token issuer of Server s
func (s *Server) TokenIssuer() issuer.Issuer {
	return s.issuer
}

func log() *logrus.Entry {
	return logrus.WithField("module", "server")
}

func (s *Server) AuthMethods() *auth.Methods {
	return s.authMethods
}

func (s *Server) Queues() *queue.SendRecvQueues {
	return s.queues
}

func (s *Server) AppManager() *application.ApplicationManager {
	return s.appManager
}

func (s *Server) agentMode(namespace string) types.AgentMode {
	s.clientLock.RLock()
	defer s.clientLock.RUnlock()
	if mode, ok := s.namespaceMap[namespace]; ok {
		return mode
	}
	return types.AgentModeUnknown
}

func (s *Server) setAgentMode(namespace string, mode types.AgentMode) {
	s.clientLock.Lock()
	defer s.clientLock.Unlock()
	s.namespaceMap[namespace] = mode
}

// func (s *Server) namespaceFromClient(clientID string) (string, error) {
// 	s.clientLock.RLock()
// 	defer s.clientLock.RUnlock()
// 	ns, ok := s.clientMap[clientID]
// 	if !ok {
// 		return "", fmt.Errorf("no mapping for client ID %s", clientID)
// 	}
// 	return ns, nil
// }

// func (s *Server) clientFromNamespace(namespace string) (string, error) {
// 	s.clientLock.RLock()
// 	defer s.clientLock.RUnlock()
// 	client, ok := s.namespaceMap[namespace]
// 	if !ok {
// 		return "", fmt.Errorf("no mapping for namespace %s", namespace)
// 	}
// 	return client, nil
// }
