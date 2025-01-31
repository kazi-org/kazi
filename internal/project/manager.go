// manager.go
//
// Defines a "ProjectManager" that composes the smaller specialized interfaces
// (DomainManager, ConfigManager, DocManager, etc.) and returns a complete Project object.

package project

import (
	"context"
	"fmt"
)

// ProjectManager is the higher-level interface that merges everything
// into a single "LoadProject" step if desired, or provides specialized methods.
type ProjectManager interface {
	// BuildProject loads domain, architecture, config, and attaches doc/log references,
	// returning a fully assembled Project object.
	BuildProject(ctx context.Context, domainPath, archPath, configPath string) (*Project, error)
}

// DefaultProjectManager composes smaller specialized managers (domain, architecture, config)
// plus optional references to doc or ephemeral logs.
type DefaultProjectManager struct {
	DomainMgr       DomainManager
	ArchMgr         ArchitectureManager
	ConfigMgr       ConfigManager
	DocMgr          DocManager
	LogMgr          EphemeralLog
	ChunkMgr        ChunkProvider
}

// BuildProject loads each piece from the specialized manager, then
// returns a complete Project struct. Each piece is optional or can be replaced.
func (pm *DefaultProjectManager) BuildProject(
	ctx context.Context,
	domainPath, archPath, configPath string,
) (*Project, error) {
	project := &Project{}

	// 1. Domain
	domainContract, err := pm.DomainMgr.LoadContract(domainPath)
	if err != nil {
		return nil, fmt.Errorf("load contract: %w", err)
	}
	project.Contract = domainContract

	// 2. Architecture
	arch, err := pm.ArchMgr.LoadArchitecture(archPath)
	if err != nil {
		return nil, fmt.Errorf("load architecture: %w", err)
	}
	project.Architecture = arch

	// 3. Config
	cfg, err := pm.ConfigMgr.LoadConfig(configPath)
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}
	project.Config = cfg

	// 4. Docs
	if pm.DocMgr != nil {
		if err := pm.DocMgr.EnsureDocs(ctx); err != nil {
			return nil, fmt.Errorf("ensure docs: %w", err)
		}
		project.DocManager = pm.DocMgr
	}

	// 5. Ephemeral logs
	if pm.LogMgr != nil {
		project.EphemeralLogger = pm.LogMgr
	}

	// 6. Chunk provider
	if pm.ChunkMgr != nil {
		project.Chunker = pm.ChunkMgr
	}

	return project, nil
}
