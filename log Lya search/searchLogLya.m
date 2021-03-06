%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Original contributor: Tin Nguyen. 
% Description: MATLAB function,
% - implement rounds of alternating optimization to find polynomials P and Q, 
% - theoretical basis: Subsection 2.4.2 of Senior Thesis 
% Dependencies: 
% - YALMIP (open-sourced LMI parser that comes with good documentation) 
% - optimizers: MOSEK or SDPT3, etc. 
% - files in project: intQ_Qh.m 
% Inputs: 
% - n, x, f, scale, noise, options: these arguments are the same as those in intQ_Qh.m 
% - dp: proposed degree of the polynomial P 
% - dq: proposed degree of the polynomial Q 
% - P_homogeneous: whether or not P is constrained to be homogeneous 
% - Q_homogeneous: whether or not Q is constrained to be homogeneous 
% - max_iter: maximum rounds of altenating optimization 
% - tol: after each search for P or Q, remove coefficients that are too small, using tol as the threshold value 
% Outputs: 
% - success: binary variable indicating success of the search,
% - err: message indicating error in the event of failure,
% - final_P: array containing coefficients of the P that appears in the final Lyapunov function, 
% - final_Q: array containing coefficients of the Q that appears in the final Lyapunov function.
% Room for improvement: 
% - Errors of the type "Struct contents reference from a non-struct array object" seem to
% + have more to do with how YALMIP objects are returned rather than numerical issues 
% + involved in the optimization problems. Resolving such errors would potentially increase the number 
% + of configuration of arguments that result in a successful search. 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [success, err, final_P, final_Q] = searchLogLya(n, x, f, noise, scale, options,...
                                     dp, dq, P_homogeneous, Q_homogeneous, max_iter, tol) 
    
    %% setup YALMIP variables and expressions 
    sdpvar t_lo t_hi
    linear_constraints = [];
    if Q_homogeneous
        vq = monolist(x,dq,dq); 
        [Q,cq,~] = polynomial(x,dq,dq);
    else
        vq = monolist(x,dq); 
        [Q,cq,~] = polynomial(x,dq);
        linear_constraints = linear_constraints + [replace(Q,x,zeros(n,1)) == 0];
    end
    if P_homogeneous
        vp = monolist(x,dp,dp); 
        [P,cp,~] = polynomial(x,dp,dp);
    else
        vp = monolist(x,dp); 
        [P,cp,~] = polynomial(x,dp);
        linear_constraints = linear_constraints + [replace(P,x,zeros(n,1)) == 0];
    end
    len_q = length(vq); 
    len_p = length(vp);
    
    grad_Q = jacobian(Q,x);
    grad_P = jacobian(P,x);
    grad_V = grad_P + (1+P)*grad_Q;
    
    lo_power = 0;
    high_power = 0;
    temp = degree(f) + dq + dp - 1;
    if mod(temp, 2) == 0
        hi_deg = temp;
    else
        hi_deg = temp - 1;
    end
    
    for i = 1:n
        lo_power = lo_power + x(i)^2;
        high_power = high_power + x(i)^hi_deg;
    end
    
    aug_derivative = -grad_V*f-t_lo*lo_power-t_hi*high_power;
    SOS_constraints = [sos(Q), sos(P), sos(aug_derivative)];
    constraints = SOS_constraints + linear_constraints;

    %% initialize Q using intQ_Qh.m 
    [int_success, curr_cq] = intQ_Qh(n, x, f, dq, noise, scale, options);   
    if (int_success == 0)
        success = 0;
        disp('intQ_Qh err: search for quadratic lyapunov not successful');
        err = 'search for quadratic lyapunov not successful';
        final_P = -1;
        final_Q = -1;
    else
        success = 1;
        
        %% YALMIP allows the definition of family of optimization problems 
        P_problem = optimizer(constraints,t_lo^2+t_hi^2,options,cq,[cp;t_lo;t_hi]);
        Q_problem = optimizer(constraints,t_lo^2+t_hi^2,options,cp,[cq;t_lo;t_hi]);
        
        %% report the progress of each round of alternating optimization 
        progress = cell(0, 7);
        progress = cell2table(progress);
        progress.Properties.VariableNames = {'iteration', 't_lo_p', 't_hi_p', 'p_prob', ...
            't_lo_q', 't_hi_q', 'q_prob'};
        disp(progress)
               
        for iter = 1:max_iter
            [Psol,p_problem] = P_problem{curr_cq};
            curr_cp = Psol(1:len_p);
            t_lo_p = Psol(len_p+1);
            t_hi_p = Psol(len_p+2);
            curr_cp = clean(curr_cp,tol);
            
            if (isnan(t_lo_p)) || (isnan(t_hi_p))
                disp('searchLogLya err: NaN appearing in model / infeasible model');
                err = 'NaN appearing in model / infeasible model';
                success = 0;
                final_P = -1;
                final_Q = -1;
                break;
            end

            [Qsol,q_problem] = Q_problem{curr_cp};
            curr_cq = Qsol(1:len_q);
            t_lo_q = Qsol(len_q+1);
            t_hi_q = Qsol(len_q+2);
            curr_cq = clean(curr_cq,tol);
            
            if (isnan(t_lo_q)) || (isnan(t_hi_q))
                disp('searchLogLya err: NaN appearing in model / infeasible model');
                success = 0;
                err = 'NaN appearing in model / infeasible model';
                final_P = -1;
                final_Q = -1;
                break;
            end
            
            entry = {iter, t_lo_p, t_hi_p, p_problem, t_lo_q, t_hi_q, q_problem}; 
            progress = [progress; entry]; 
            if (abs(t_lo_p) < tol && abs(t_hi_p) < tol && abs(t_lo_q) < tol && abs(t_hi_q) < tol && ...
                     q_problem == 0 && p_problem == 0)
                disp('Perfect: Time-derivative is negative and lyapunov function vanishes at 0');
                break;
            end
        end
        
        disp(progress)

        %% Sanity check
        if ~success
            disp('searchLogLya err: Some err before sanity check');
            err = 'Some err before sanity check';
            success = 0;
            final_P = -1;
            final_Q = -1;
            return
        end
        
        %% clean final solution 
        sanity_tol = 1e-5;    
        P = clean(curr_cp,sanity_tol)'*vp;
        grad_P = jacobian(P,x);
        Q = clean(curr_cq,sanity_tol)'*vq;
        grad_Q = jacobian(Q,x);
        grad_V = grad_P + (1+P)*grad_Q;
        time_derivative = -grad_V*f;
        
        if (isa(P,'double') || isa(Q,'double'))
            disp('searchLogLya err: P or Q is too close to 0');
            err = 'P or Q is too close to 0';
            success = 0;
            final_P = -1;
            final_Q = -1;
            return 
        end
             
        constraints = [sos(P),sos(Q),sos(time_derivative)];
        linear_constraints = [replace(P,x,zeros(n,1)) == 0];
        try
            [~,~,gram] = solvesos(constraints,0,options);
        catch 
            err = 'Struct contents reference from a non-struct array object (in sanity check)';
            success = 0;
            final_P = -1;
            final_Q = -1;
        end
            
        try
            if (linear_constraints == true) && (min(eig(gram{1})) > 0) && (min(eig(gram{2})) > 0) ...
                    (min(eig(gram{3})) > 0)
                err = 'None';
                check(constraints)
                min(eig(gram{1}))
                min(eig(gram{2}))
                min(eig(gram{3}))
                success = 1;
                final_P = P;
                final_Q = Q;
            else
                disp('err: Did not pass the sanity check');
                err = 'Did not pass the sanity check';
                success = 0;
                final_P = -1;
                final_Q = -1;
            end
        catch
            err = 'Solvesos does not return gram matrices as intended (in sanity check)';
            success = 0;
            final_P = -1;
            final_Q = -1;
    end
end
