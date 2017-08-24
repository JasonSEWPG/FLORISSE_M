function [inputData] = floris_loadSettings(modelType,turbType,siteType,atmoType)
%% Site and topology settings
switch siteType
    case '9turb'
        % Wind turbine locations in inertial frame 
        inputData.LocIF = [300,    100.0;
                           300,    300.0;
                           300,    500.0;
                           1000,   100.0;
                           1000,   300.0;
                           1000,   500.0;
                           1600,   100.0;
                           1600,   300.0;
                           1600,   500.0];
               
        % Atmospheric settings
        inputData.uInfIf   = 12;       % x-direction flow speed inertial frame (m/s)
        inputData.vInfIf   = 4;        % y-direction flow speed inertial frame (m/s)
        inputData.airDensity = 1.1716; % Atmospheric air density (kg/m3)
                
        % The following values are only necessary for Porte-Agels wake model
        inputData.turbIntensity = 0.10;
        inputData.shear         = 0.12;
        
    otherwise
        error(['Site type with name "' siteType '" not defined']);
end
              
%% FLORIS model settings        
switch lower(modelType)
    case {'default'}  %% original tuning parameters
        % Choice of how a turbine's axial control setting is determined
        % 0: use pitch angles and Cp-Ct LUTs for pitch and WS, 
        % 1: greedy control   and Cp-Ct LUT for WS,
        % 2: specify axial induction directly.
        inputData.axialControlMethod = 0;  
        
        inputData.pP                = 1.88; % yaw power correction parameter
        inputData.Ke                = 0.05; % wake expansion parameters
        inputData.KeCorrCT          = 0.0; % CT-correction factor
        inputData.baselineCT        = 4.0*(1.0/3.0)*(1.0-(1.0/3.0)); % Baseline CT for ke-correction
        inputData.me                = [-0.5, 0.22, 1.0]; % relative expansion of wake zones
        inputData.KdY               = 0.17; % Wake deflection recovery factor
        
        % define initial wake displacement and angle (not determined by yaw angle)
        inputData.useWakeAngle      = true;
        inputData.kd                = deg2rad(1.5);  % initialWakeAngle in X-Y plane
        inputData.ad                = -4.5; % initialWakeDisplacement
        inputData.bd                = -0.01;
        
        % correction recovery coefficients with yaw
        inputData.useaUbU           = true;
        inputData.aU                = 12.0; % units: degrees
        inputData.bU                = 1.3;
        
        inputData.MU                = [0.5, 1.0, 5.5];
        
        % adjust initial wake diameter to yaw
        inputData.adjustInitialWakeDiamToYaw = false;   
        
    case {'gebraad'}  %% original tuning parameters
        % Choice of how a turbine's axial control setting is determined
        % 0: use pitch angles and Cp-Ct LUTs for pitch and WS, 
        % 1: greedy control   and Cp-Ct LUT for WS,
        % 2: specify axial induction directly.
        inputData.axialControlMethod = 2;  
        
        inputData.pP                = 1.88; % yaw power correction parameter
        inputData.Ke                = 0.05; % wake expansion parameters
        inputData.KeCorrCT          = 0.0; % CT-correction factor
        inputData.baselineCT        = 4.0*(1.0/3.0)*(1.0-(1.0/3.0)); % Baseline CT for ke-correction
        inputData.me                = [-0.5, 0.22, 1.0]; % relative expansion of wake zones
        inputData.KdY               = 0.17; % Wake deflection recovery factor
        
        % define initial wake displacement and angle (not determined by yaw angle)
        inputData.useWakeAngle      = true;
        inputData.kd                = deg2rad(1.5);  % initialWakeAngle in X-Y plane
        inputData.ad                = -4.5; % initialWakeDisplacement
        inputData.bd                = -0.01;
        
        % correction recovery coefficients with yaw
        inputData.useaUbU           = true;
        inputData.aU                = 12.0; % units: degrees
        inputData.bU                = 1.3;
        
        inputData.MU                = [0.5, 1.0, 5.5];
        
        % adjust initial wake diameter to yaw
        inputData.adjustInitialWakeDiamToYaw = false;        
                
    otherwise
        error(['Model type with name: "' modelType '" not defined']);
end

%% Turbine settings
switch lower(turbType)
    case 'nrel5mw'
        nTurbs                          = size(inputData.LocIF,1);
        inputData.nTurbs                = nTurbs;
        inputData.rotorRadius           = (126.4/2) * ones(1,nTurbs);
        inputData.generator_efficiency  = 0.944     * ones(1,nTurbs);
        inputData.hub_height            = 90.0      * ones(1,nTurbs);
        
        inputData.LocIF(:,3)            = inputData.hub_height;
        
        % Control settings
%         inputData.yawAngles   = zeros(1,nTurbs);     % Set default as greedy
        inputData.yawAngles   = deg2rad([-27 10 -30 -30 -20 -15 0 10 0]);
        inputData.tiltAngles  = zeros(1,nTurbs);     % Set default as greedy
        inputData.pitchAngles = zeros(1,nTurbs);     % Only relevant if inputData.axialControlMethod == 0
        inputData.axialInd    = 1/3*ones(1,nTurbs);  % Only relevant if inputData.axialControlMethod == 2
                   
    otherwise
        error(['Turbine type with name "' turbType '" not defined']);
end

%% Post-processing
% Compute windDirection and magnitude
inputData.windDirection = atand(inputData.vInfIf/inputData.uInfIf); % Wind dir in degrees (inertial frame)
inputData.uInfWf        = hypot(inputData.uInfIf,inputData.vInfIf); % axial flow speed in wind frame

switch lower(atmoType)
    case 'boundary'
        % initialize the flow field used in the 3D model based on shear using the power log law
        inputData.Ufun = @(z) inputData.uInfWf.*(z./90).^inputData.shear;
    case 'uniform'
        inputData.Ufun = @(z) inputData.uInfWf;
    otherwise
        error(['Atmosphere type with name "' atmoType '" not defined']);
end

% Compute control settings and turbine DOF
if inputData.axialControlMethod == 0  % Control through blade pitch
    inputData.axialInd = NaN*ones(1,nTurbs); % set axInd as NaN to avoid confusion 

    % Determine Cp and Ct interpolation functions as a function of WS and blade pitch
    for airfoilDataType = {'cp','ct'}
        lut        = csvread([airfoilDataType{1} 'Pitch.csv']);
        lut_ws     = lut(1,2:end);          % Wind speed in LUT in m/s
        lut_pitch  = deg2rad(lut(2:end,1)); % Blade pitch angle in LUT in radians
        lut_value  = lut(2:end,2:end);      % Values of Cp/Ct [dimensionless]
        inputData.([airfoilDataType{1} '_interp'])  = @(ws,pitch) interp2(lut_ws,lut_pitch,lut_value,ws,pitch);
    end
    
elseif inputData.axialControlMethod == 1 % Greedy control with LUT for wind speed
    inputData.pitchAngles    = NaN*ones(1,nTurbs); % set blade pitch as NaN to avoid confusion
    inputData.axialInd       = NaN*ones(1,nTurbs); % Create empty vector

    % Determine Cp and Ct interpolation functions as a function of WS
    lut                      = load('NREL5MWCPCT.mat');
    inputData.('cp_interp')  = @(ws) interp1(lut.NREL5MWCPCT.wind_speed,lut.NREL5MWCPCT.CP,ws);
    inputData.('ct_interp')  = @(ws) interp1(lut.NREL5MWCPCT.wind_speed,lut.NREL5MWCPCT.CT,ws);
    
elseif inputData.axialControlMethod == 2 % Directly control axial induction factor (ADM)
    inputData.pitchAngles = NaN*ones(1,nTurbs); % set blade pitch as NaN to avoid confusion
    
else
    error('Please specify inputData.axialControlMethod as 0, 1 or 2.');
end

for i = 1:nTurbs
    inputData.rotorArea(i) = pi*inputData.rotorRadius(i).^2;
end